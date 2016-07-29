require 'spec_helper'

describe Spree::Retailops::RopLineItemUpdater do
  let(:line_item_params) do
    [
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
    ]
  end

  let(:modified_line_item_params) do
    [
      {
        "estimated_extended_cost" => "27.50",
        "apportioned_ship_amt" => 4.98,
        "sku" => "136270",
        "quantity" => "2",
        "estimated_ship_date" => 1458221964,
        "direct_ship_amt" => 0,
        "corr" => "575714",
        "removed" => nil,
        "estimated_cost" => 27.5,
        "estimated_unit_cost" => 27.5,
        "unit_price" => 49.98
      }
    ]
  end

  let(:line_items) do
    line_item_params.map do |line_item_hash|
      create(:line_item, {
        quantity: line_item_hash["quantity"].to_i,
        cost_price: line_item_hash["estimated_unit_cost"].to_d,
        price: line_item_hash["unit_price"].to_d,
        variant: create(:variant, sku: line_item_hash["sku"])
      })
    end
  end

  let(:order) do
    create(:order, line_items: line_items)
  end

  describe "#call" do
    it "will return false in first item of result when there are no changes" do
      changed, _ = Spree::Retailops::RopLineItemUpdater.new(order, line_item_params).call
      expect(changed).to eq(false)
    end

    it "will return results in second item of result" do
      _, result = Spree::Retailops::RopLineItemUpdater.new(order, line_item_params).call
      expect(result.class).to eq(Array)
      expect(result.first[:corr]).to eq("575714")
    end

    it "will return true in the first item of result when there are changes" do
      changed, _ = Spree::Retailops::RopLineItemUpdater.new(order, modified_line_item_params).call
      expect(changed).to eq(true)
    end
  end
end
