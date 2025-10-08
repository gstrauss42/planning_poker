Rails.application.routes.draw do
  # Health check endpoint
  get "up" => "rails/health#show", as: :rails_health_check

  # Main app
  root "estimations#index"
  
  # API endpoints
  post "estimations/submit"
  post "estimations/reveal"
  post "estimations/clear"
  post "estimations/fetch_jira_ticket"
  get "estimations/session_state", to: "estimations#get_session_state"
  get "estimations/health", to: "estimations#health_check"
end