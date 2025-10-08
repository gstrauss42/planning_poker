#!/bin/bash

# Setup script for Redis to ensure synchronization works properly

echo "Setting up Redis for Planning Poker synchronization..."

# Check if Redis is already running
if pgrep -x "redis-server" > /dev/null; then
    echo "Redis is already running"
else
    echo "Redis is not running. Starting Redis..."
    
    # Try to start Redis with different methods
    if command -v redis-server &> /dev/null; then
        echo "Starting Redis server..."
        redis-server --daemonize yes --port 6379
        sleep 2
        
        # Test connection
        if redis-cli ping | grep -q "PONG"; then
            echo "✅ Redis started successfully"
        else
            echo "❌ Failed to start Redis"
            exit 1
        fi
    else
        echo "Redis is not installed. Please install Redis:"
        echo ""
        echo "On macOS: brew install redis"
        echo "On Ubuntu: sudo apt-get install redis-server"
        echo "On CentOS: sudo yum install redis"
        echo ""
        echo "Then run this script again."
        exit 1
    fi
fi

# Test Redis connection
echo "Testing Redis connection..."
if redis-cli ping | grep -q "PONG"; then
    echo "✅ Redis connection successful"
    echo "Redis is ready for Planning Poker synchronization"
else
    echo "❌ Redis connection failed"
    exit 1
fi

echo ""
echo "🎉 Redis setup complete! You can now run the Planning Poker application."
echo "The application will use Redis for atomic state management and perfect synchronization."
