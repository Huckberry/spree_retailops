module Spree
  module Retailops
    class RopOrderHelper
      attr_accessor :order, :options

      def standard_shipping_label
        'Standard Shipping'
      end

      # There is a major impedence mismatch between Spree and RetailOps on the subject of ship pricing.  Spree assigns a ship price (which confusingly is called
      # a "shipment cost") to each shipment/package, while RetailOps supports shipping lines at the order and ordered-item level.
      #
      # When an order is being actively managed by the RetailOps integration, we want a consistent price between systems, so when an order is managed we combine
      # all of the shipment prices into a single price which is used on the RetailOps side and also stashed on the order, either as a global adjustment
      # (matching historical spree_retailops behavior, and arguably more correct for multi-shipment orders) or as the price on one of the shipments (arguably
      # more correct for single-shipment orders).
      def separate_shipment_costs
        return false if @order.canceled?
        return apply_shipment_price(effective_shipping_price)
      end

      def effective_shipping_price
        extracted_total = 0.to_d
        @order.shipments.each do |shipment|
          # Spree 2.1.x: shipment costs are expressed as order adjustments linked through source to the shipment
          # Spree 2.2.x: shipments have a cost which is authoritative, and one or more adjustments (shiptax, etc)
          cost = if shipment.respond_to?(:adjustment)
            shipment.adjustment.try(:amount) || 0.to_d
          else
            shipment.cost + shipment.adjustment_total
          end

          extracted_total += cost if cost > 0
        end

        order_ship_adj = @order.adjustments.where(label: standard_shipping_label).first
        extracted_total += order_ship_adj.amount if order_ship_adj


        return extracted_total
      end

      # 2015-02-27: Transforming shipments to an advisory shipping method turns out to be a bad idea because that loses the information about what the original
      # shipping method was, and we need that information in order to recalculate the shipping price for new/removed items in the new 'delegated' mode.  So
      # instead, keep the existing shipment method, but set the adjustment to 0 and close it.
      #
      # When doing writebacks in RO-authoritative mode, price is the total RO shipping price while order_level is the part not attached to any line.
      def apply_shipment_price(price, order_level = nil)
        changed = false
        return false if @order.canceled?

        if @order.respond_to?(:retailops_set_shipping_amt)
          return @order.retailops_set_shipping_amt( total_shipping_amt: price, order_shipping_amt: order_level )
        end

        target_ship = nil

        if Spree::Config[:retailops_express_shipping_price] != "adjustment"
          target_ship = @order.shipments.to_a.reject(&:shipped?).first || @order.shipments.first
        end

        @order.shipments.each do |shipment|
          this_ship_price = 0
          if shipment == target_ship
            this_ship_price = price
            price = 0 # do not need adjustment
          end

          rate = shipment.selected_shipping_rate
          unless shipment.selected_shipping_rate
            # probably shouldn't happen
            shipment.add_shipping_method(rop_tbd_method, true)
            rate = shipment.selected_shipping_rate
            shipment.save! # ensure that the adjustment is created
            changed = true
          end

          if shipment.respond_to?(:adjustment_total) && shipment.adjustment_total > 0
            shipment.adjustments.delete_all
          end

          if shipment.cost != this_ship_price
            changed = true
            rate.cost = this_ship_price
            rate.save!

            if shipment.respond_to?(:adjustment)
              #shipment.ensure_correct_adjustment # adjustment ought to exist by now...

              # Override and lock the shipment adjustment so that normal Spree rules won't apply to change it
              adj = shipment.adjustment
              adj.amount = this_ship_price
              adj.close if adj.open?
              adj.save!
            end
            # otherwise setting the shipping rate was enough.  Can't actually close a shipping rate but hopefully those won't be recalculated too often
            shipment.cost = this_ship_price
            shipment.save!
          end
        end

        order_ship_adj = @order.adjustments.where(label: standard_shipping_label).first
        if price > 0 && !order_ship_adj
          @order.adjustments.create!(amount: price, label: standard_shipping_label, mandatory: false)
          @order.save!
          changed = true
        elsif order_ship_adj && order_ship_adj.amount != price
          order_ship_adj.amount = price
          order_ship_adj.save!
          @order.save!
          changed = true
        end
      end

      # Create a single package virtually containing all of the items of this order to recalculate a shipping price using the order's rules.  Note that this
      # bypasses the usual checks for availability and zone that usually happen prior to an invocation of a shipping calculator; hopefully this will not cause
      # problems.  It does not account for shipping tax and is probably unsuitable for use with "active shipping" type solutions.
      def calculate_ship_price
        contents = []
        stock_location = nil
        method = nil

        @order.shipments.order(:id).each do |ship|
          pkg = ship.to_package
          meth = ship.shipping_method
          if meth && !meth.calculator.is_a?(Spree::Calculator::Shipping::RetailopsAdvisory)
            # this is a legit shipping method that can be used for recalculation
            method ||= meth
            stock_location ||= pkg.stock_location
          end
          contents += pkg.contents
        end


        return method && method.calculator.compute(Spree::Stock::Package.new( stock_location, @order, contents ))
      end

      def rop_tbd_method
        advisory_method(options["partial_ship_name"] || "Unshipped")
      end

      # Find or create an advisory (not selectable) shipping method to represent how ROP shipped this item
      def advisory_method(name)
        use_any_method = options["use_any_method"]
        @advisory_methods ||= {}
        unless @advisory_methods[name]
          @advisory_methods[name] = ShippingMethod.where(admin_name: name).detect { |s| use_any_method || s.calculator.is_a?(Spree::Calculator::Shipping::RetailopsAdvisory) }
        end

        unless @advisory_methods[name]
          raise "Advisory shipping method #{name} does not exist and automatic creation is disabled" if options["no_auto_shipping_methods"]
          @advisory_methods[name] = ShippingMethod.create!(name: name, admin_name: name) do |m|
            m.calculator = Spree::Calculator::Shipping::RetailopsAdvisory.new
            m.shipping_categories << ShippingCategory.first
          end
        end
        @advisory_methods[name]
      end
    end
  end
end
