require 'spec_helper'

describe Spree::Api::Retailops::OrdersController do
  let(:params) do
    {
      "order_amts" => {
        "shipping_amt" => 4.98,
        "discount_amt" => 0,
        "tax_amt" => 0,
        "direct_tax_amt" => 0
      },
      "rmas" => nil,
      "line_items" => [
        {
          "estimated_extended_cost" => "27.50",
          "apportioned_ship_amt" => 4.98,
          "sku" => "136270",
          "quantity" => "1",
          "estimated_ship_date" => 1458221964,
          "direct_ship_amt" => 0,
          "corr" => "575714",
          "removed" => nil,
          "estimated_cost" => 27.5,
          "estimated_unit_cost" => 27.5,
          "unit_price" => 49.98
        }
      ],
      "options" => {},
      "order_refnum" => "R280725117",
      "order" => {}
    }
  end

  let(:line_items) do
    params["line_items"].map do |line_item_hash|
      create(:line_item, {
        quantity: line_item_hash["quantity"].to_i,
        cost_price: line_item_hash["estimated_unit_cost"].to_d,
        price: line_item_hash["unit_price"].to_d,
        variant: create(:variant, sku: line_item_hash["sku"])
      })
    end
  end

  let(:order) do
    create(:order, number: params["order_refnum"], line_items: line_items)
  end

  let(:user) { create(:admin_user, spree_api_key: "key") }

  let(:mock_handler) do
    Struct.new(:order, :params) do
      def call
        [true, []]
      end
    end
  end

  before do
    order
  end

  describe "#synchronize" do
    it "will call out to default line item processor" do
      expect_any_instance_of(Spree::Retailops::RopLineItemUpdater).to receive(:call).and_return([true, []])
      post :synchronize, params.merge(use_route: :synchronize_retailops_api, token: user.spree_api_key)
      response_data = JSON.parse(response.body)
      expect(response_data["changed"]).to be(true)
    end

    it "will call out custom line item processor if it exists" do
      stub_const("RetailopsLineItemUpdateHandler", mock_handler)
      expect_any_instance_of(RetailopsLineItemUpdateHandler).to receive(:call).and_call_original
      post :synchronize, params.merge(use_route: :synchronize_retailops_api, token: user.spree_api_key)
      response_data = JSON.parse(response.body)
      expect(response_data["changed"]).to be(true)
    end
  end
end
