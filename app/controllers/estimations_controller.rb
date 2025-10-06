class EstimationsController < ApplicationController
  def index
  end

  def submit
    user_name = params[:user_name]
    points = params[:points]

    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "submit",
        user_name: user_name,
        points: points
      }
    )

    head :ok
  end

  def reveal
    ActionCable.server.broadcast(
      "estimation_session",
      { action: "reveal" }
    )

    head :ok
  end

  def clear
    ActionCable.server.broadcast(
      "estimation_session",
      { action: "clear" }
    )

    head :ok
  end

  def set_ticket
    ticket_title = params[:ticket_title]

    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "set_ticket",
        ticket_title: ticket_title
      }
    )

    head :ok
  end
end