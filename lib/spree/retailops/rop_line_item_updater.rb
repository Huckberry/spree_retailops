module Spree
  module Retailops
    class RopLineItemUpdater
      # This class handles the updates to the line items (and associated records)
      # when a syncrhonization request comes in from ROPs. You can customize this
      # behavior by defining your own `RetailopsLineItemUpdateHandler` in the host
      # application. It should accept the same parameters for initialization, define
      # the `#call` method, and return the same "tuple" as the `#call` method
      # defined here.
      #
      # @param [Spree::Order] order This is a reference to a Spree::Order and
      #                             should be updated in place.
      # @param [Array] line_item_params These are the raw parameters for line items
      #                                 sent from RetailOps. Example below.
      #
      # [
      #   {
      #     "estimated_extended_cost" => "27.50",
      #     "apportioned_ship_amt" => 4.98,
      #     "sku" => "136270",
      #     "quantity" => "1",
      #     "estimated_ship_date" => 1458221964,
      #     "direct_ship_amt" => 0,
      #     "corr" => "575714",
      #     "removed" => nil,
      #     "estimated_cost" => 27.5,
      #     "estimated_unit_cost" => 27.5,
      #     "unit_price" => 49.98
      #   }
      # ]
      #
      def initialize(order, line_item_params)
        @order = order
        @line_item_params = line_item_params
        @changed = false
        @result = []
      end

      # This method is called to perform the all the updates required to the line
      # items and order.
      #
      # It should return an array of two items. The first item is a boolean that
      # is true if something was changed, and the second is an array of the the
      # changes as hashes.
      #
      # @return [Array[Boolean, Array]] The first item is true if there are changes.
      #                                 The secont item is an array of hashes containing
      #                                 information RetailOps needs to update internal
      #                                 systems based on this response.
      def call
        used_v = {}

        line_item_params.each do |lirec|
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
              mark_changed!
            end
            next
          end

          next if !li && qty == oldqty # should be caught by <= 0

          if qty > oldqty
            mark_changed!
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

            li = order.contents.add(variant, qty - oldqty, shipment: shipment)
          elsif qty < oldqty
            mark_changed!
            li = order.contents.remove(variant, oldqty - qty)
          end

          if lirec["estimated_unit_cost"]
            cost = lirec["estimated_unit_cost"].to_d
            if cost > 0 and li.cost_price != cost
              mark_changed!
              li.update!(cost_price: cost)
            end
          end

          if lirec["unit_price"]
            price = lirec["unit_price"].to_d
            if li.price != price
              li.update!(price: price)
              mark_changed!
            end
          end

          if li.respond_to?(:estimated_ship_date=) && li.estimated_ship_date != eshp
            mark_changed!
            li.update!(estimated_ship_date: eshp)
          end

          if li.respond_to?(:retailops_set_estimated_ship_date)
            mark_changed! if li.retailops_set_estimated_ship_date(eshp)
          end

          if li.respond_to?(:retailops_extension_writeback)
            # well-known extensions - known to ROP but not Spree
            extra["direct_ship_amt"] = lirec["direct_ship_amt"].to_d.round(4) if lirec["direct_ship_amt"]
            extra["apportioned_ship_amt"] = lirec["apportioned_ship_amt"].to_d.round(4) if lirec["apportioned_ship_amt"]
            mark_changed! if li.retailops_extension_writeback(extra)
          end

          result << { corr: corr, refnum: li.id, quantity: li.quantity }
        end

        [changed, result]
      end

      private

      attr_accessor :order, :line_item_params, :result, :changed

      def mark_changed!
        @changed = true
      end
    end
  end
end
