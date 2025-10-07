# config/initializers/cache_configuration.rb

# Ensure cache is properly configured for session storage
Rails.application.config.after_initialize do
  # Log cache configuration
  Rails.logger.info "Cache Store: #{Rails.cache.class.name}"
  
  # Ensure cache is enabled (especially important for development)
  if Rails.env.development? && !Rails.root.join("tmp/caching-dev.txt").exist?
    Rails.logger.warn "=" * 60
    Rails.logger.warn "Cache is disabled in development!"
    Rails.logger.warn "Run 'rails dev:cache' to enable caching"
    Rails.logger.warn "This is required for Planning Poker session storage"
    Rails.logger.warn "=" * 60
  end
  
  # Test cache is working
  begin
    Rails.cache.write("test_key", "test_value", expires_in: 1.second)
    if Rails.cache.read("test_key") == "test_value"
      Rails.logger.info "✓ Cache is working properly"
    else
      Rails.logger.error "✗ Cache write/read test failed!"
    end
  rescue => e
    Rails.logger.error "✗ Cache test failed: #{e.message}"
  end
end