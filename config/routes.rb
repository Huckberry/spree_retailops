Spree::Core::Engine.routes.draw do
  namespace :api do
    namespace :retailops do
      post 'catalog', to: 'catalog#catalog_push'
      post 'inventory', to: 'inventory#inventory_push'

      post 'orders', to: 'orders#index'
      post 'orders/mark_exported', to: 'orders#export'
      post 'orders/synchronize', to: 'orders#synchronize'
      post 'orders/add_packages', to: 'settlement#add_packages'
      post 'orders/mark_complete', to: 'settlement#mark_complete'
      post 'orders/add_refund', to: 'settlement#add_refund'
      post 'orders/payment_command', to: 'settlement#payment_command'
      post 'orders/cancel', to: 'settlement#cancel'
    end
  end

  #compat
  scope module: "api" do
    namespace :retailops do
      post 'catalog', to: 'catalog#catalog_push'
      post 'inventory', to: 'inventory#inventory_push'
    end
  end

  namespace :admin do
    resource :retailops_integration_settings, :only => ['update', 'edit']
  end

  namespace :api do
    put 'orders/:id/retailops_importable', to: 'orders#retailops_importable'
  end
end
