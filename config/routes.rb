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
  post "estimations/fetch_sprint_tickets"
  post "estimations/navigate_ticket"
  post "estimations/async_fetch_sprint_tickets"
  post "estimations/async_fetch_jira_ticket"
  post "estimations/async_vote"
  post "estimations/async_reveal"
  post "estimations/async_clear"
  get "estimations/session_state", to: "estimations#get_session_state"
  get "estimations/health", to: "estimations#health_check"
  get "jira_images/:attachment_id", to: "estimations#proxy_jira_image"
end
