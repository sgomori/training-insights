Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Ingestion. Authenticated by a shared bearer secret; the senders are the
  # fit-pipeline project and the n8n health metric workflow.
  namespace :webhooks do
    post "activity", to: "activities#create"
    post "health_metric", to: "health_metrics#create"
  end

  # The MCP server — the project's primary artifact. Mounted through a lambda so
  # the endpoint constant resolves per request and survives code reloading.
  mount ->(env) { McpEndpoint.call(env) } => "/mcp", as: :mcp_server

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # The public site — one page, no visitor accounts.
  root "home#show"
end
