module Spree
  module Api
    module Retailops
      class OrdersController < Spree::Api::BaseController
        # This function handles fetching order data for RetailOps.  In the spirit of
        # pushing as much maintainance burden as possible onto RetailOps and not
        # requiring different versions per client, we return data in a fairly raw
        # state.  This also needs to be relatively fast.  Since we cannot guarantee
        # that the other side will receive and correctly process the data we return
        # (there might be a badly timed network dropout, or *gasp* a bug), we don't
        # mark orders as exported here - that's handled in export below.

        module Extractor
          INCLUDE_BLOCKS = {}
          LOOKUP_LISTS = {}

          def self.use_association(klass, syms, included = true)
            syms.each do |sym|
              to_assoc = klass.reflect_on_association(sym) or next
              to_incl_block = to_assoc.polymorphic? ? {} : (INCLUDE_BLOCKS[to_assoc.klass] ||= {})
              incl_block = INCLUDE_BLOCKS[klass] ||= {}
              incl_block[sym] = to_incl_block
              (LOOKUP_LISTS[klass] ||= {})[sym] = true if included
            end
          end

          def self.ad_hoc(klass, sym, need = [])
            use_association klass, need, false
            (LOOKUP_LISTS[klass] ||= {})[sym] = Proc.new
          end

          use_association Order, [:line_items, :adjustments, :shipments, :ship_address, :bill_address, :payments]

          use_association LineItem, [:adjustments]
          ad_hoc(LineItem, :sku, [:variant]) { |i| i.variant.try(:sku) }
          ad_hoc(LineItem, :advisory, [:variant]) { |i| p = i.variant.try(:product); i.try(:retailops_is_advisory?) || p.try(:retailops_is_advisory?) || p.try(:is_gift_card) }
          ad_hoc(LineItem, :expected_ship_date, []) { |i| i.try(:retailops_expected_ship_date) }

          use_association Variant, [:product], false

          use_association Shipment, [:adjustments]
          ad_hoc(Shipment, :shipping_method_name, [:shipping_rates]) { |s| s.shipping_method.try(:name) }

          use_association ShippingRate, [:shipping_method], false

          ad_hoc(Address, :state_text, [:state]) { |a| a.state_text }
          ad_hoc(Address, :country_iso, [:country]) { |a| a.country.try(:iso) }

          use_association Payment, [:source]
          ad_hoc(Payment, :method_class, [:payment_method]) { |p| p.payment_method.try(:type) }

          def self.walk_order_obj(o)
            ret = {}
            o.class.column_names.each { |cn| ret[cn] = o.public_send(cn).as_json }
            if list = LOOKUP_LISTS[o.class]
              list.each do |sym, block|
                if block.is_a? Proc
                  ret[sym.to_s] = block.call(o)
                else
                  relat = o.public_send(sym)
                  if relat.is_a? ActiveRecord::Relation
                    relat = relat.map { |rec| walk_order_obj rec }
                  elsif relat.is_a? ActiveRecord::Base
                    relat = walk_order_obj relat
                  end
                  ret[sym.to_s] = relat
                end
              end
            end
            return ret
          end

          def self.root_includes
            INCLUDE_BLOCKS[Order] || {}
          end
        end

        def index
          authorize! :read, [Order, LineItem, Variant, Payment, PaymentMethod, CreditCard, Shipment, Adjustment]

          query = options['filter'] || {}
          query['completed_at_not_null'] ||= 1
          query['retailops_import_eq'] ||= 'yes'
          results = Order.ransack(query).result.limit(params['limit'] || 50).includes(Extractor.root_includes)

          render text: results.map { |o|
            begin
              Extractor.walk_order_obj(o)
            rescue Exception => ex
              Rails.logger.error("Order export failed: #{ex.to_s}:\n  #{ex.backtrace * "\n  "}")
              { "error" => ex.to_s, "trace" => ex.backtrace, "number" => o.number }
            end
          }.to_json
        end

        def export
          authorize! :update, Order
          ids = params["ids"]
          raise "ids must be a list of numbers" unless ids.is_a?(Array) && ids.all? { |i| i.is_a? Fixnum }

          missing_ids = ids - Order.where(id: ids, retailops_import: ['done', 'yes']).pluck(:id)
          raise "order IDs could not be matched or marked nonimportable: " + missing_ids.join(', ') if missing_ids.any?

          Order.where(retailops_import: 'yes', id: ids).update_all(retailops_import: 'done')
          render text: {}.to_json
        end

        # This probably calls update! far more times than it needs to as a result of line item hooks, etc
        # Exercise for interested parties: fix that
        #
        # Here are example parameters
        #
        #
        # {
        #   "order_amts" => {
        #     "shipping_amt" => 4.98,
        #     "discount_amt" => 0,
        #     "tax_amt" => 0,
        #     "direct_tax_amt" => 0
        #   },
        #   "rmas" => nil,
        #   "line_items" => [
        #     {
        #       "estimated_extended_cost" => "27.50",
        #       "apportioned_ship_amt" => 4.98,
        #       "sku" => "136270",
        #       "quantity" => "1",
        #       "estimated_ship_date" => 1458221964,
        #       "direct_ship_amt" => 0,
        #       "corr" => "575714",
        #       "removed" => nil,
        #       "estimated_cost" => 27.5,
        #       "estimated_unit_cost" => 27.5,
        #       "unit_price" => 49.98
        #     }
        #   ],
        #   "options" => {},
        #   "order_refnum" => "R280725117",
        #   "order" => {}
        # }
        #
        def synchronize
          authorize! :update, Order
          changed = false
          result = []
          order = Order.find_by!(number: params["order_refnum"].to_s)
          @helper = Spree::Retailops::RopOrderHelper.new
          @helper.order = order
          @helper.options = options
          ActiveRecord::Base.transaction do
            # RetailOps will be sending in an authoritative (potentially updated) list of line items
            # We make our data match that as well as possible, and then send the list back annotated
            # with channel_refnums and quantities/costs/etc

            used_v = {}

            params["line_items"].to_a.each do |lirec|
              corr = lirec["corr"].to_s
              sku  = lirec["sku"].to_s
              qty  = lirec["quantity"].to_i
              eshp = Time.at(lirec["estimated_ship_date"].to_i)
              extra = lirec["ext"] || {}

              variant = Spree::Variant.find_by(sku: sku)
              next unless variant
              next if qty <= 0
              next if used_v[variant]
              used_v[variant] = true

              li = order.find_line_item_by_variant(variant)
              oldqty = li ? li.quantity : 0

              if lirec["removed"]
                if li
                  order.contents.remove(li.variant, li.quantity)
                  changed = true
                end
                next
              end

              next if !li && qty == oldqty # should be caught by <= 0

              if qty > oldqty
                changed = true
                # make sure the shipment that will be used, exists
                # expanded for 2.1.x compat
                shipment = order.shipments.detect do |shipment|
                  (shipment.ready? || shipment.pending?) && shipment.include?(variant)
                end

                shipment ||= order.shipments.detect do |shipment|
                  (shipment.ready? || shipment.pending?) && variant.stock_location_ids.include?(shipment.stock_location_id)
                end

                unless shipment
                  shipment = order.shipments.build
                  shipment.state = 'ready'
                  shipment.stock_location_id = variant.stock_location_ids[0]
                  shipment.save!
                end

                li = order.contents.add(variant, qty - oldqty, {shipment: shipment})
              elsif qty < oldqty
                changed = true
                li = order.contents.remove(variant, oldqty - qty)
              end

              if lirec["estimated_unit_cost"]
                cost = lirec["estimated_unit_cost"].to_d
                if cost > 0 and li.cost_price != cost
                  changed = true
                  li.update!(cost_price: cost)
                end
              end

              if lirec["unit_price"]
                price = lirec["unit_price"].to_d
                if li.price != price
                  li.update!(price: price)
                  changed = true
                end
              end

              if li.respond_to?(:estimated_ship_date=) && li.estimated_ship_date != eshp
                changed = true
                li.update!(estimated_ship_date: eshp)
              end

              if li.respond_to?(:retailops_set_estimated_ship_date)
                changed = true if li.retailops_set_estimated_ship_date(eshp)
              end

              if li.respond_to?(:retailops_extension_writeback)
                # well-known extensions - known to ROP but not Spree
                extra["direct_ship_amt"] = lirec["direct_ship_amt"].to_d.round(4) if lirec["direct_ship_amt"]
                extra["apportioned_ship_amt"] = lirec["apportioned_ship_amt"].to_d.round(4) if lirec["apportioned_ship_amt"]
                changed = true if li.retailops_extension_writeback(extra)
              end

              result << { corr: corr, refnum: li.id, quantity: li.quantity }
            end
            items_changed = changed
            order.all_adjustments.tax.each { |a| a.close if a.open? } # Allow tax to organically recalculate

            # omitted RMAs are treated as 'no action'
            params["rmas"].to_a.each do |rma|
              changed = true if sync_rma order, rma
            end

            ro_amts = params['order_amts'] || {}
            if options["ro_authoritative_ship"]
              if ro_amts["shipping_amt"]
                total = ro_amts["shipping_amt"].to_d
                item_level = 0.to_d + params['line_items'].to_a.collect{ |l| l['direct_ship_amt'].to_d }.sum
                changed = true if @helper.apply_shipment_price(total, total - item_level)
              end
            elsif items_changed
              calc_ship = @helper.calculate_ship_price
              # recalculate and apply ship price if we still have enough information to do so
              # calc_ship may be nil otherwise
              @helper.apply_shipment_price(calc_ship) if calc_ship
            end

            if changed
              # Allow tax to organically recalculate
              # *slightly* against the spirit of adjustments to automatically reopen them, but this is triggered on item changes which are (generally) human-initiated in RO
              if items_changed
                order.all_adjustments.tax.each { |a| a.fire_state_event(:open) if a.closed? }
                order.adjustments.promotion.each { |a| a.fire_state_event(:open) if a.closed? }
              end

              order.update!

              order.all_adjustments.tax.each { |a| a.close if a.open? }
              order.adjustments.promotion.each { |a| a.close if a.open? }
            end


            if order.respond_to?(:retailops_after_writeback)
              order.retailops_after_writeback(params)
            end

            order.update! if changed
          end

          render text: {
            changed: changed,
            dump: Extractor.walk_order_obj(order),
            result: result,
          }.to_json
        end

        def sync_rma(order, rma_params)
          # This is half of the RMA/return push mechanism: it handles RMAs created in RetailOps by
          # creating matching RMAs in Spree numbered RMA-ROP-NNN.  Any inventory which has been
          # returned in RetailOps will have a corresponding RetailOps return; if that exists in
          # Spree, then we *exclude* that inventory from the RMA being created and delete the RMA
          # when all items are removed.

          # Calls out to the parent application's custom handling for RMA data. The data
          # is passed from ROPs to the controller in the following format, and will be passed
          # straight through the underlying application.
          #
          # {
          #     "discount_amt": 0,
          #     "id": "10067",
          #     "items": [
          #         {
          #             "channel_refnum": "605775",
          #             "order_item_id": "223845",
          #             "quantity": "1",
          #             "sku": "101575"
          #         }
          #     ],
          #     "product_amt": 114.98,
          #     "refund_amt": 114.98,
          #     "returns": [
          #         {
          #             "discount_amt": 0,
          #             "id": "6128",
          #             "items": [
          #                 {
          #                     "channel_refnum": "605775",
          #                     "order_item_id": "223845",
          #                     "quantity": "1",
          #                     "sku": "101575"
          #                 }
          #             ],
          #             "product_amt": 114.98,
          #             "refund_amt": 114.98,
          #             "shipping_amt": 0,
          #             "subtotal_amt": 114.98,
          #             "tax_amt": 0
          #         }
          #     ],
          #     "shipping_amt": 0,
          #     "subtotal_amt": 114.98,
          #     "tax_amt": 0
          # }
          #
          order.process_retail_ops_rma(rma_params)
        end

        private
        def options
          params['options'] || {}
        end
      end
    end
  end
end
