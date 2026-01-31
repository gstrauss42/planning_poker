# config/initializers/redis_cleanup.rb
# Cleanup Redis connections on application shutdown

Rails.application.configure do
  # Cleanup Redis connections when the application shuts down
  at_exit do
    begin
      AtomicStateManager.cleanup_on_shutdown
    rescue StandardError => e
      Rails.logger.error "[RedisCleanup] Error during shutdown cleanup: #{e.message}"
    end
  end
end
