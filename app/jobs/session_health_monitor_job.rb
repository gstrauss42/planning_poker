# app/jobs/session_health_monitor_job.rb
class SessionHealthMonitorJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "[SessionHealthMonitorJob] Starting periodic health check"
    
    begin
      health_report = SessionMonitor.monitor_session_health
      
      # Log health status
      if health_report[:overall_health] < 70
        Rails.logger.warn "[SessionHealthMonitorJob] Session health degraded: #{health_report[:overall_health]}%"
      end
      
      # Store metrics for monitoring dashboards
      store_health_metrics(health_report)
      
    rescue StandardError => e
      Rails.logger.error "[SessionHealthMonitorJob] Health monitoring failed: #{e.message}"
    end
  end

  private

  def store_health_metrics(health_report)
    # Store in Redis for real-time monitoring
    metrics = {
      timestamp: Time.current.to_i,
      health_score: health_report[:overall_health],
      redis_latency: health_report[:redis_status][:latency],
      state_issues_count: health_report[:state_issues].length,
      presence_issues_count: health_report[:presence_issues].length,
      stale_sessions_count: health_report[:stale_sessions].length
    }
    
    AtomicStateManager.redis.setex(
      "session_health_metrics",
      300, # 5 minutes
      metrics.to_json
    )
  end
end
