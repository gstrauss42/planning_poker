module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :connection_identifier

    def connect
      self.connection_identifier = SecureRandom.uuid
    end
  end
end