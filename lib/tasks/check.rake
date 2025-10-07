# lib/tasks/monitor.rake
namespace :monitor do
  desc "Monitor session state changes in real-time"
  task session: :environment do
    puts "Monitoring Planning Poker Session (Ctrl+C to stop)"
    puts "=" * 60
    
    last_version = -1
    last_vote_count = 0
    
    loop do
      state = EstimationSessionStore.get_broadcast_state
      
      # Only print if something changed
      if state[:version] != last_version || state[:votes].count != last_vote_count
        puts "\n[#{Time.current.strftime('%H:%M:%S')}]"
        puts "  Version: #{state[:version]}"
        puts "  Ticket: #{state[:ticket_title] || 'None'}"
        puts "  Votes: #{state[:votes].keys.join(', ') || 'None'}"
        puts "  Revealed: #{state[:revealed]}"
        puts "  Connected: #{state[:connected_count]}"
        puts "  Voted: #{state[:voted_count]}/#{state[:connected_count]}"
        
        last_version = state[:version]
        last_vote_count = state[:votes].count
      end
      
      sleep 1
    end
  end
  
  desc "Test broadcast functionality"
  task broadcast_test: :environment do
    puts "Broadcasting test message..."
    
    state = EstimationSessionStore.get_broadcast_state
    
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "sync_state",
        state: state
      }
    )
    
    puts "✓ Broadcast sent"
    puts "Check browser consoles for '[WebSocket] Received' message"
  end
end