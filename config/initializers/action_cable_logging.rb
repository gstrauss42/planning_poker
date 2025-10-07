# config/initializers/action_cable_logging.rb
# Enhanced logging for ActionCable to help debug synchronization issues

if Rails.env.development? || ENV['ENABLE_CABLE_DEBUG'].present?
  ActionCable.server.config.logger = Logger.new(STDOUT)
  ActionCable.server.config.logger.level = Logger::DEBUG
  
  # Log all broadcasts
  module ActionCable
    module Server
      module Broadcasting
        alias_method :original_broadcast, :broadcast
        
        def broadcast(broadcasting, message)
          Rails.logger.info "[ActionCable Broadcast] Channel: #{broadcasting}"
          Rails.logger.info "[ActionCable Broadcast] Message: #{message.inspect[0..500]}"
          original_broadcast(broadcasting, message)
        end
      end
    end
  end
  
  Rails.logger.info "ActionCable debug logging enabled"
end