#!/bin/bash

# Redis Debug Script for Planning Poker
echo "🔍 Redis Debug Script for Planning Poker"
echo "========================================"

# Check if Redis is running
echo ""
echo "1. Checking if Redis is running..."
if pgrep -x "redis-server" > /dev/null; then
    echo "✅ Redis server is running"
    echo "   PID: $(pgrep -x redis-server)"
else
    echo "❌ Redis server is not running"
    echo "   Run: redis-server"
    exit 1
fi

# Test Redis connection
echo ""
echo "2. Testing Redis connection..."
if redis-cli ping | grep -q "PONG"; then
    echo "✅ Redis connection successful"
else
    echo "❌ Redis connection failed"
    exit 1
fi

# Check Redis info
echo ""
echo "3. Redis server info..."
redis-cli info server | grep -E "(redis_version|uptime_in_seconds|connected_clients)"

# Check Redis memory usage
echo ""
echo "4. Redis memory usage..."
redis-cli info memory | grep -E "(used_memory_human|maxmemory_human)"

# Test Redis operations
echo ""
echo "5. Testing Redis operations..."
redis-cli set "test_key" "test_value"
if redis-cli get "test_key" | grep -q "test_value"; then
    echo "✅ Redis read/write operations working"
else
    echo "❌ Redis read/write operations failed"
fi
redis-cli del "test_key"

# Check for Planning Poker keys
echo ""
echo "6. Checking for Planning Poker keys..."
keys=$(redis-cli keys "*estimation*")
if [ -n "$keys" ]; then
    echo "✅ Found Planning Poker keys:"
    echo "$keys"
else
    echo "ℹ️  No Planning Poker keys found (this is normal for a fresh session)"
fi

# Test Redis latency
echo ""
echo "7. Testing Redis latency..."
latency=$(redis-cli --latency -h localhost -p 6379 -c 5 | tail -1)
echo "   Average latency: $latency"

# Check Redis configuration
echo ""
echo "8. Redis configuration..."
redis-cli config get "*timeout*"
redis-cli config get "*maxmemory*"

echo ""
echo "🎉 Redis debug complete!"
echo ""
echo "If you're still having issues:"
echo "1. Check your REDIS_URL environment variable"
echo "2. Ensure Redis is accessible from your Rails app"
echo "3. Check firewall settings if using remote Redis"
echo "4. Look at Rails logs for detailed error messages"
