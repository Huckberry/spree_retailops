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
            # We make our data match that as well as possible, and then send the list back annotated with channel_refnums and quantities/costs/etc

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

        def sync_rma(order, rma)
          # This is half of the RMA/return push mechanism: it handles RMAs created in RetailOps by
          # creating matching RMAs in Spree numbered RMA-ROP-NNN.  Any inventory which has been
          # returned in RetailOps will have a corresponding RetailOps return; if that exists in
          # Spree, then we *exclude* that inventory from the RMA being created and delete the RMA
          # when all items are removed.

          # find Spree RMA.  bail out if received (shouldn't happen)
          return unless order.shipped_shipments.any?  # avoid RMA create failures
          spree_rma = find_rma(order, rma)

          #Return if everything's been recieved
          return if spree_rma.present? && rma_received?(spree_rma)

          #If the rma exists, sync return items
          if spree_rma.present?
            rma['items'].to_a.each do |item|
              if !has_item?(spree_rma, item)
                add_item_to_rma(spree_rma, item)
              end
            end
            rma['returns'].to_a.each do |ret|
              #Create a customer return
              if ret['items'].to_a.size > 0
                cust_return = Spree::CustomerReturn.new(stock_location: order.shipped_shipments.first.stock_location, number: ret["id"])
                spree_return_items = []
                ret['items'].to_a.each do |item|
                  if item['quantity'].to_i > 0
                    if !has_item?(spree_rma, item)
                      add_item_to_rma(spree_rma, item)
                    end
                    spree_return_item = find_return_item(spree_rma, item)
                    if spree_return_item.count <= item['quantity'].to_i
                      spree_return_items << spree_return_item.slice(0..(item['quantity'].to_i - 1))
                    end
                  end
                end
                cust_return.return_items = spree_return_items.flatten!
                cust_return.save

                # Require Manual Intervention if the items if the refund amount is 0. A 0 here
                # means that the item was received but we cannot resell it. It's possible we should
                # still issue a refund here, for example if the customer received the item damaged.
                if ret['refund_amt'].to_i == 0
                  spree_return_items.each { |sri| sri.require_manual_intervention }
                end
              end
            end

          else

            spree_rma = create_spree_rma(order,rma)
            return true
          end



        end

        private
        def options
          params['options'] || {}
        end

        def find_rma(order, rma)
          rop_rma_str = "#{rma["id"]}"
          spree_rma = order.return_authorizations.detect { |r| r.number == rop_rma_str }
        end

        def create_spree_rma(order, rma)
          rop_rma_str = "#{rma["id"]}"
          rma_obj = order.return_authorizations.build
          rma_obj.number = rop_rma_str
          rma_obj.stock_location_id = order.shipped_shipments.first.stock_location_id
          rma_obj.reason = Spree::ReturnAuthorizationReason.where("name like '%Retail Ops%'").first || Spree::ReturnAuthorizationReason.first
          rma_obj.save

          rma["items"].to_a.each do |it|
            add_item_to_rma(rma_obj, it, order)
          end
          rma_obj
        end

        def has_item?(spree_rma, item)
          spree_rma.return_items.includes(inventory_unit: [:variant]).map{|a| a.variant.sku == item['sku']}.any?
        end
        def find_return_item(spree_rma, item)
          spree_rma.return_items.includes(inventory_unit: [:variant]).select{|a| a.variant.sku == item['sku']}
        end
        def add_item_to_rma(spree_rma, item, order)
          iu = order.inventory_units.select{|iu| iu.line_item_id.to_s == item["channel_refnum"].to_s}.first
          return_item = spree_rma.return_items.build
          return_item.inventory_unit = iu
          return_item.pre_tax_amount = iu.try(:line_item).try(:price).try(:to_f)
          return_item.save
        end

        def rma_received?(spree_rma)
          return false unless spree_rma.present?
          received = true
          spree_rma.return_items.each{|ri| received = false unless ri.received?}
          received
        end
      end
    end
  end
end
