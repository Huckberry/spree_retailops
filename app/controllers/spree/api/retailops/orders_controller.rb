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

          options = params['options'] || {}
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

        def synchronize
          authorize! :update, Order
          changed = false
          result = []
          order = Order.find_by!(number: params["order_refnum"].to_s)
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

                li = order.contents.add(variant, qty - oldqty, nil, shipment)
              elsif qty < oldqty
                changed = true
                li = order.contents.remove(variant, oldqty - qty)
              end

              if lirec["estimated_unit_cost"]
                cost = BigDecimal.new(lirec["estimated_unit_cost"].to_f, 2)
                if cost > 0 and li.cost_price != cost
                  changed = true
                  li.update!(cost_price: cost)
                end
              end

              if lirec["unit_price"]
                price = BigDecimal.new(lirec["unit_price"], 2)
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
                extra["direct_ship_amt"] = BigDecimal.new(lirec["direct_ship_amt"], 2) if lirec["direct_ship_amt"]
                extra["apportioned_ship_amt"] = BigDecimal.new(lirec["apportioned_ship_amt"], 2) if lirec["apportioned_ship_amt"]
                changed = true if li.retailops_extension_writeback(extra)
              end

              result << { corr: corr, refnum: li.id, quantity: li.quantity }
            end

            # omitted RMAs are treated as 'no action'
            params["rmas"].to_a.each do |rma|
              changed = true if sync_rma order, rma
            end

            if params["shipping_amt"]
              if order.respond_to?(:retailops_set_shipping_amt)
                total = BigDecimal.new(params["shipping_amt"], 2)
                item_level = BigDecimal.new(0,2) + params['line_items'].to_a.collect{ |l| BigDecimal.new(l['direct_ship_amt'], 2) }.sum

                changed = true if order.retailops_set_shipping_amt(
                  total_shipping_amt: total,
                  order_shipping_amt: total - item_level
                )
              else
                changed = true if sync_shipping_amt order, BigDecimal.new(params["shipping_amt"], 2)
              end
            end

            # get tax/discount totals from RetailOps and create adjustments for any discrepancy
            # discount done first because it makes assumptions about nonstaleness
            order.update! if changed

            if params["discount_amt"]
              discount_amt = BigDecimal.new(params["discount_amt"],2)
              changed = true if order.respond_to?(:retailops_set_order_discount_amount) ? order.retailops_set_order_discount_amount(discount_amt) : set_order_discount(order, discount_amt)
            end

            if params["tax_amt"]
              tax_amt = BigDecimal.new(params["tax_amt"],2)
              changed = true if order.respond_to?(:retailops_set_order_tax) ? order.retailops_set_order_tax(tax_amt) : set_order_tax(order, tax_amt)
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

        def set_order_tax(order, tax_amt)
          apparent_tax_amt = order.respond_to?(:additional_tax_total) ? order.additional_tax_total : order.tax_total
          set_discrepancy_adjustment(order, 'Tax set in RetailOps', tax_amt, apparent_tax_amt, false)
        end

        def set_order_discount(order, discount_amt)
          apparent_discount_amt = order.try(:discount_total) || order.adjustment_total
          # Fudge: ROP tax adjustments are interpreted by Spree as discounts
          order.adjustments.each do |a|
            if a.label == 'Tax set in RetailOps' || a.label == 'Standard Shipping'
              apparent_discount_amt -= a.amount
            end
          end
          set_discrepancy_adjustment(order, 'Discount set in RetailOps', -discount_amt, apparent_discount_amt, true)
        end

        def set_discrepancy_adjustment(order, label, rop_amt, apparent_amt, adj_included_in_apparent)
          adj = order.adjustments.detect { |a| a.label == label }
          adj_amt = adj ? adj.amount : 0
          apparent_amt -= adj_amt if adj_included_in_apparent
          changed = false

          if rop_amt != apparent_amt
            changed = true
            adj ||= order.adjustments.create(order: order, amount: rop_amt - apparent_amt, label: label, mandatory: false)
            adj.amount = rop_amt - apparent_amt
            adj.save!
          end

          return changed
        end

        def sync_shipping_amt(order, amt)
          changed = false

          helper = Spree::Retailops::RopOrderHelper.new
          helper.order = order
          helper.options = params["options"]
          changed = true if helper.separate_shipment_costs

          # All Spree shipment charges have been transmogrified to a "Standard Shipping" adjustment.  Need a non-label-based way to identify these

          adj = order.adjustments.detect { |a| a.label == 'Standard Shipping' } #XXX
          adj_amt = adj ? adj.amount : 0

          if adj_amt != amt
            changed = true
            adj ||= order.adjustments.create(order: order, amount: amt, label: "Standard Shipping", mandatory: false)
            adj.amount = amt
            adj.save!
          end

          return changed
        end

        def sync_rma(order, rma)
          # This is half of the RMA/return push mechanism: it handles RMAs created in RetailOps by
          # creating matching RMAs in Spree numbered RMA-ROP-NNN.  Any inventory which has been
          # returned in RetailOps will have a corresponding RetailOps return; if that exists in
          # Spree, then we *exclude* that inventory from the RMA being created and delete the RMA
          # when all items are removed.

          # find Spree RMA.  bail out if received (shouldn't happen)
          return unless order.shipped_shipments.any?  # avoid RMA create failures
          rop_rma_str = "RMA-RO-#{rma["id"].to_i}"
          rma_obj = order.return_authorizations.detect { |r| r.number == rop_rma_str }
          return if rma_obj && rma_obj.received?

          # for each ROP return: check if it exists in Spree.  Reduce RMA amount for returns that
          # have been filed.

          closed_value = BigDecimal.new(0)
          closed_items = {}

          rma["returns"].to_a.each do |ret|
            ret_str = "RMA-RET-#{ret["id"].to_i}"
            ret_obj = order.return_authorizations.detect { |r| r.number == ret_str }

            if ret_obj && ret_obj.received?
              closed_value += BigDecimal.new(ret['refund_amt'],2) - (ret['tax_amt'] ? (BigDecimal.new(ret['tax_amt'],2) + BigDecimal.new(ret['shipping_amt'],2)) : 0)
              ret["items"].to_a.each do |it|
                it_obj = order.line_items.detect { |i| i.id.to_s == it["channel_refnum"].to_s }
                closed_items[it_obj] = (closed_items[it_obj] || 0) + it["quantity"].to_i if it_obj
              end
            end
          end

          use_items = {}
          use_total = 0

          rma["items"].to_a.each do |it|
            line = order.line_items.detect { |i| i.id.to_s == it["channel_refnum"].to_s } or next
            use_items[line] = [ 0, it["quantity"].to_i - (closed_items[line] || 0) ].max
          end

          use_items.each do |li, qty|
            use_total += qty
          end

          # create RMA if not exists and items > 0
          return if !rma_obj && use_total <= 0

          unless rma_obj
            rma_obj = order.return_authorizations.build
            rma_obj.number = rop_rma_str
            rma_obj.save! # have an ID *before* adding items
            changed = true
          end

          # set RMA item quantities

          changed = false

          order.line_items.each do |li|
            # this function is misnamed, it sets, it does not add
            changed = true # use rma_obj.inventory_units to identify changes if it ever becomes necessary
            rma_obj.add_variant(li.variant_id, use_items[li] || 0)
          end

          # delete RMA if all items gone
          if use_total == 0
            rma_obj.destroy!
            return true
          end

          # set RMA amount
          if rma["subtotal_amt"].present? || rma["refund_amt"].present?
            use_value = BigDecimal.new(rma['refund_amt'],2) - (rma['tax_amt'] ? (BigDecimal.new(rma['tax_amt'],2) + BigDecimal.new(rma['shipping_amt'],2)) : 0) - closed_value
            if use_value != rma_obj.amount
              rma_obj.amount = use_value
              changed = true
            end
          end

          rma_obj.save! if changed
          return true
        end

        private
          def options
            params['options'] || {}
          end
      end
    end
  end
end
