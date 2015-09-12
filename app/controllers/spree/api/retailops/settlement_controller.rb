module Spree
  module Api
    module Retailops
      class SettlementController < Spree::Api::BaseController
        # "Settlement" subsystem - called by ROP when there are large changes in the status of the order.
        #
        # * First we add zero or more "packages" of things we were able to ship.
        #
        # * Then we flag the order as complete - this means ROP will not be shipping any more.  Often everything will have been shipped.  Sometimes not.  Oversells and short ships are af will add a negative
        #   adjustment if the order was short shipped.  Depending on
        #   configuration this may also cause automatic capturing or refunding of
        #   payments.
        #
        # * Then (later, and hopefully not at all) we can add refunds for
        #   inventory returned in ROP.

        # Package adding: This reflects a fairly major impedence mismatch
        # between ROP and Spree, insofar as Spree wants to create shipments at
        # checkout time and charge exact shipping, while ROP standard practice
        # is to charge an abstraction of shipping that's close enough on
        # average, and then decide the details of how this order will be
        # shipped when it's actually ready to go out the door.  Because of this
        # we have to fudge stuff a bit on shipment and recreate the Spree
        # shipments to reflect how ROP is actually shipping it, so that the
        # customer has the most actionable information.  A complication is that
        # Spree's shipping rates are tied to the shipment, and need to be
        # converted into order adjustments before we start mangling the
        # shipments.  Credit where due: this code is heavily inspired by some
        # code written by @schwartzdev for @dotandbo to handle an Ordoro
        # integration.
        def add_packages
          ActiveRecord::Base.transaction do
            find_order
            ship_price = @order_helper.effective_shipping_price
            params["packages"].to_a.each do |pkg|
              extract_items_into_package pkg
            end
            @order_helper.apply_shipment_price(ship_price)
          end
          render text: {}.to_json
        end

        # The Spree core appears to reflect two schools of thought on
        # refunding.  The user guide suggests that one reason you might edit
        # orders is if you could not ship them, which suggests handling short
        # ships by modifying the order itself, then refunding by the difference
        # between the new order value and the payment.  The core code itself
        # handles returns by creating an Adjustment for the returned
        # merchandise, and leaving the line items alone.
        #
        # We follow the latter approach because it allows us to keep RetailOps
        # as the sole authoritative source of refund values, avoiding useless
        # mismatch warnings.
        def mark_complete
          ActiveRecord::Base.transaction do
            find_order
            ship_price = @order_helper.effective_shipping_price
            assert_refund_adjustments params['refund_items'], true
            @order_helper.apply_shipment_price(ship_price)
          end
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        def add_refund
          ActiveRecord::Base.transaction do
            find_order
            assert_return params
            @order.update!
          end
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        def payment_command
          find_order

          case params['command']
          when 'partial_settle'
            partial_settle(params['mode'])
            render text: @settlement_results.to_json
          else
            throw 'Unsupported payment command'
          end
        end

        # duplicates /api/order/:num/cancel but it seems useful to have a single point of contact
        def cancel
          find_order
          @order.cancel! unless @order.canceled?
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        private
          def options
            params['options'] || {}
          end

          # What order is being settled?
          def find_order
            @order = Order.find_by!(number: params["order_refnum"].to_s)
            authorize! :update, @order

            @order_helper = Spree::Retailops::RopOrderHelper.new
            @order_helper.order = @order
            @order_helper.options = options
          end

          def extract_items_into_package(pkg)
            return if @order.canceled?
            number = 'P' + pkg["id"].to_i.to_s
            tracking = pkg["tracking"].to_s
            line_items = pkg["contents"].to_a
            from_location_name = pkg["from"].to_s

            from_location = Spree::StockLocation.find_or_create_by!(name: from_location_name) { |l| l.admin_name = from_location_name }

            shipment = @order.shipments.where( "number = ? OR number LIKE ?", number, "#{number}-%" ).first # tolerate Spree's disambiguative renaming
            if shipment
              apply_shipcode shipment, pkg
              shipment.save!
              return # idempotence
              # TODO: not sure if we should allow adding stuff after the shipment ships
            end

            shipment = @order.shipments.build

            shipment.number = number
            shipment.stock_location = from_location

            collect_inventory_units

            line_items.to_a.each do |item|
              line_item = @order.line_items.find(item["id"].to_i)
              quantity = item["quantity"].to_i

              # move existing inventory units
              reused = collected_units_for_line_item(line_item).slice!(0, quantity)

              shipment.inventory_units.concat(reused)
              quantity -= reused.count

              # limit transfered units to ordered units
            end

            shipment.save!

            apply_shipcode shipment, pkg

            shipment.state = 'ready'
            shipment.ship!
            shipment.save!

            @order.shipments.reload
            @order.shipments.each do |s|
                s.reload
                s.destroy! if s.manifest.empty?
            end
            @order.reload
            @order.update!
          end

          def apply_shipcode(shipment, pkg)
            if shipment.respond_to? :retailops_set_tracking
              shipment.retailops_set_tracking(pkg)
              return
            end

            shipcode = pkg["shipcode"].to_s
            shipment.tracking = pkg['tracking'].to_s
            shipment.created_at = Time.parse(pkg['date'].to_s)

            # ShippingMethod|extrafield:value|extrafield:value
            method, *fields = shipcode.split('|')
            method = URI.parser.unescape(method.encode(Encoding::UTF_8))
            assocs = nil

            fields.each do |part|
              name, value = part.split(':')
              value = URI.parser.unescape(value.encode(Encoding::UTF_8))

              assocs ||= shipment.class.reflect_on_all_associations.each_with_object({}) { |a,h| h[a.name.to_s] = a.klass }

              if shipment.respond_to? "retailops_extend_#{name}="
                shipment.public_send("retailops_extend_#{name}=", value)
              elsif assocs.key? name
                shipment.attributes = { name => assocs[name].find_or_create_by!(name: value) }
              elsif shipment.class.column_names.include? name
                shipment.attributes = { name => value }
              end
            end

            shipment.shipping_rates.delete_all
            shipment.cost = 0.to_d
            shipment.add_shipping_method(@order_helper.advisory_method(method), true)
          end

          InvUnitsByLineItem = Spree::InventoryUnit.column_names.include? 'line_item_id'

          def collect_inventory_units
            @existing_units = @order.inventory_units.reject{ |u| u.shipped? || u.returned? }.group_by(&(InvUnitsByLineItem ? :line_item_id : :variant_id))
          end

          def collected_units_for_line_item(li)
            @existing_units[ InvUnitsByLineItem ? li.id : li.variant_id ] ||= []
          end

          def assert_return(info)
            # find Spree return, bail out if exists
            rop_return_id = info["return_id"].to_i
            rop_rma_id = info["rma_id"].to_i # may be nil->0

            return_obj = @order.return_authorizations.detect { |r| r.number == "RMA-RET-#{rop_return_id}" }
            deduct_rma_obj = @order.return_authorizations.detect { |r| r.number == "RMA-RO-#{rop_rma_id}" }

            return if return_obj # if it exists but isn't received we're in a pretty weird state because we're supposed to receive in the same txn we create

            # count up current inventory units, verify inventory for the return
            # NOTE: spree 2.1.6 does not do per-line-item inventory units
            return_by_variant = {}

            info["return_items"].present? or throw "cannot push empty return"
            @order.shipped_shipments.any? or throw "order is not shipped"
            info["return_items"].to_a.each do |ri|
              liid = ri["channel_refnum"].to_i
              li = @order.line_items.detect { |l| l.id == liid }
              return_by_variant[li.variant] = ri["quantity"].to_i if li
            end

            # always decrement for the RMA which we are receiving against, if there is one and it has been pushed to Spree already
            # if we can't satisfy the return from the named RMA, pull stuff from other RMAs

            eligible_rmas = @order.return_authorizations.with_state('authorized').reject { |r| r == deduct_rma_obj }.to_a
            eligible_rmas.unshift(deduct_rma_obj) if deduct_rma_obj
            modified_rmas = []

            return_by_variant.each do |var,qty|
              eligible_rmas.each do |rma|
                qty_here = rma.inventory_units.where(variant_id: var.id).size
                take = [ qty_here, qty ].max
                if take > 0
                  qty -= take
                  rma.add_variant(var.id, qty_here - take)
                  modified_rmas << rma
                end
              end
            end

            modified_rmas.uniq.each do |r|
              r.destroy! if r.inventory_units.reload.empty?
            end

            # if room can be made, room has been made

            # create an RMA for our return
            return_obj = @order.return_authorizations.build
            return_obj.number = "RMA-RET-#{rop_return_id}"
            return_obj.stock_location_id = @order.shipped_shipments.first.stock_location_id # anything will be wrong since we don't want spree to restock :x
            return_obj.save! # needs an ID before we can add stuf

            sloc = Spree::StockLocation.find(return_obj.stock_location_id) # "rma.stock_location" crashes.  possible has_one/has_many mixup?
            return_by_variant.each do |var,qty|
              sloc.set_up_stock_item(var) # receive! crashes if there is no stock item
              return_obj.add_variant(var.id, qty)
            end

            # optionally check completeness here?

            # set value
            # these might come in as strings, so coerce *before* summing
            return_obj.amount = info['refund_amt'].to_d - (info['tax_amt'] ? (info['tax_amt'].to_d + info['shipping_amt'].to_d) : 0.to_d)
            return_obj.save!

            # receive it
            return_obj.receive!

            # refund_amt (the only field sent by previous versions of the RO driver) is the total amount to refund
            # refund_amt = subtotal_amt + tax_amt + shipping_amt - [total restocking fees] + [rounding error]

            # Possible issue: any restocking fee < 5 cents is likely actually rounding noise
            # Possible issue: Setting "Refund" = No for an item will be treated the same as nulling the refund with a restocking fee

            if info['tax_amt']
              shipping_amt = info['shipping_amt'].to_d
              tax_amt = info['tax_amt'].to_d

              @order.adjustments.create!(amount: -shipping_amt, label: "Return #{rop_return_id} Shipping") if shipping_amt.nonzero?
              @order.adjustments.create!(amount: -tax_amt, label: "Return #{rop_return_id} Tax") if tax_amt.nonzero?
            end
          end

          def assert_refund_adjustments(refunds, cancel_ship)
            return if @order.canceled?
            collect_inventory_units

            refunds.to_a.each do |item|
              created = nil
              @order.adjustments.find_or_create_by!(label: item["label"].to_s) { |adj| adj.amount = -item["amount"].to_d; created = true }

              if created && cancel_ship
                line_item = @order.line_items.find(item["id"].to_i)
                collected_units_for_line_item(line_item).slice!(0, item['quantity'].to_i).each(&:destroy!)
              end
            end

            if cancel_ship
              @order.shipments.each { |s| s.reload; s.destroy! if s.inventory_units.empty? }
            end
            @order.reload
          end


          # If something goes wrong with a multi-payment order, we want to log
          # it and keep going.  We may get what we need from other payments,
          # otherwise we want to make as much progress as possible...
          def rescue_gateway_error
            yield
          rescue Spree::Core::GatewayError => e
            @settlement_results["errors"] << e.message
          ensure
            @order.reload
          end

          # avoid infinite loops and only process a given payment once
          def pick_payment(&blk)
            @payments_available ||= @order.payments.to_a
            chosen = @payments_available.detect(&blk)
            @payments_available.delete(chosen) if chosen
            chosen
          end

          # Try to get payment on a completed order as tidy as possible subject
          # to your automation settings.  For maximum idempotence, returns the
          # new state so that RetailOps can reconcile its own notion of the
          # payment state.
          def settle_payments_if_desired
            partial_settle(capture: true, partial_capture: true, void: true, refund: true)
          end

          def partial_settle(cmd)
            @settlement_results = { "errors" => [], "status" => [] }
            bias = cmd['target'] ? BigDecimal.new(cmd['target']) - @order.total : BigDecimal.new(0)

            op = nil

            unless @order.canceled?
              while (cmd["capture"] && options["ok_capture"]) && (@order.outstanding_balance + bias) > 0 && op = pick_payment { |opp| opp.pending? && opp.amount > 0 && opp.amount <= (@order.outstanding_balance + bias) }
                rescue_gateway_error { op.capture! }
              end

              while (cmd["partial_capture"] && options["ok_partial_capture"]) && (@order.outstanding_balance + bias) > 0 && op = pick_payment { |opp| opp.pending? && opp.amount > 0 && opp.amount > (@order.outstanding_balance + bias) }
                # Spree 2.2.x allows you to pass an argument to
                # Spree::Payment#capture! but this does not seem to do quite
                # what we want.  In particular the payment system treats the
                # remainder of the payment as pending.
                op.amount = (@order.outstanding_balance + bias)
                rescue_gateway_error { op.capture! }
              end

              while (cmd["void"] && options["ok_void"]) && (@order.outstanding_balance + bias) <= 0 && op = pick_payment { |opp| opp.pending? && opp.amount > 0 }
                rescue_gateway_error { op.void_transaction! }
              end

              while (cmd["refund"] && options["ok_refund"]) && (@order.outstanding_balance + bias) < 0 && op = pick_payment { |opp| opp.completed? && opp.can_credit? }
                rescue_gateway_error { op.credit! } # remarkably, THIS one picks the right amount for us
              end
            end

            # collect payment data
            @order.payments.select{|op| op.amount > 0}.each do |op|
              @settlement_results["status"] << { "id" => op.id, "state" => op.state, "amount" => op.amount, "credit" => op.offsets_total.abs }
            end
          end
      end
    end
  end
end
