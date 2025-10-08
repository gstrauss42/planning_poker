# app/services/jira_service.rb
class JiraService
  class JiraError < StandardError; end
  
  def initialize
    @base_url = Rails.application.credentials.dig(:jira, :base_url)
    @email = Rails.application.credentials.dig(:jira, :email)
    @api_token = Rails.application.credentials.dig(:jira, :api_token)
    @project = Rails.application.credentials.dig(:jira, :project)
    @board_id = Rails.application.credentials.dig(:jira, :board_id)
    
    # Optional: Custom field IDs for acceptance criteria and technical writeup
    @acceptance_criteria_field = Rails.application.credentials.dig(:jira, :acceptance_criteria_field)
    @technical_writeup_field = Rails.application.credentials.dig(:jira, :technical_writeup_field)
    
    validate_credentials!
  end

  # Accepts either full JIRA URL or just ticket key (e.g., "PROJ-123")
  def fetch_ticket(input)
    ticket_key = extract_ticket_key(input)
    
    # Optional: Validate ticket belongs to your project
    if @project.present? && ticket_key.present?
      project_from_key = ticket_key.split('-').first
      unless project_from_key.casecmp(@project).zero?
        raise JiraError, "Ticket #{ticket_key} is not from your project (#{@project})"
      end
    end
    
    url = "#{@base_url}/rest/api/3/issue/#{ticket_key}"
    
    # Include attachments and other fields we need
    fields_list = ["summary", "description", "status", "priority", "assignee", "issuetype", "attachment"]
    
    # Add custom fields if configured
    fields_list << @acceptance_criteria_field if @acceptance_criteria_field.present?
    fields_list << @technical_writeup_field if @technical_writeup_field.present?
    
    params = {
      fields: fields_list.join(","),
      expand: "renderedFields"
    }
    
    response = HTTParty.get(
      url,
      basic_auth: { username: @email, password: @api_token },
      headers: { 'Content-Type' => 'application/json' },
      query: params
    )

    if response.success?
      parse_ticket_response(response)
    else
      handle_error_response(response)
    end
  rescue StandardError => e
    Rails.logger.error("JIRA API Error: #{e.message}")
    raise JiraError, "Failed to fetch ticket: #{e.message}"
  end

  private

  def validate_credentials!
    missing = []
    missing << "base_url" unless @base_url.present?
    missing << "email" unless @email.present?
    missing << "api_token" unless @api_token.present?
    
    if missing.any?
      raise JiraError, "Missing JIRA credentials: #{missing.join(', ')}. Please configure in credentials.yml"
    end
    
    # Project and board_id are optional but recommended
    Rails.logger.warn("JIRA project not configured") unless @project.present?
    Rails.logger.warn("JIRA board_id not configured") unless @board_id.present?
  end

  def extract_ticket_key(input)
    return nil if input.blank?
    
    # If it's a full URL, extract the ticket key
    if input.match?(/https?:\/\//)
      # Match patterns like: /browse/PROJ-123 or /issues/PROJ-123
      match = input.match(/\/(?:browse|issues?)\/([A-Z]+-\d+)/i)
      match ? match[1] : nil
    else
      # Assume it's already a ticket key (e.g., "PROJ-123")
      input.match?(/^[A-Z]+-\d+$/i) ? input : nil
    end
  end

  def parse_ticket_response(response)
    data = response.parsed_response
    
    # Get description (might be in different formats)
    raw_description = extract_description(data)
    
    # Parse sections from description
    sections = parse_description_sections(raw_description)
    
    # Try to get acceptance criteria from custom field if configured
    acceptance_criteria = if @acceptance_criteria_field.present?
      field_value = data.dig("fields", @acceptance_criteria_field)
      Rails.logger.debug "[JiraService] Acceptance criteria field '#{@acceptance_criteria_field}' value: #{field_value.inspect}"
      extract_field_value(field_value)
    else
      Rails.logger.debug "[JiraService] No acceptance criteria field configured, using parsed sections"
      sections[:acceptance_criteria]
    end
    
    # Try to get technical writeup from custom field if configured
    technical_writeup = if @technical_writeup_field.present?
      field_value = data.dig("fields", @technical_writeup_field)
      Rails.logger.debug "[JiraService] Technical writeup field '#{@technical_writeup_field}' value: #{field_value.inspect}"
      extract_field_value(field_value)
    else
      Rails.logger.debug "[JiraService] No technical writeup field configured, using parsed sections"
      sections[:technical_writeup]
    end
    
    # Get attachments
    attachments = extract_attachments(data)
    
    Rails.logger.debug "[JiraService] Found #{attachments.count} attachments for ticket #{data['key']}"
    
    {
      key: data["key"],
      summary: data.dig("fields", "summary"),
      description: sections[:description] || raw_description,
      acceptance_criteria: acceptance_criteria,
      technical_writeup: technical_writeup,
      attachments: attachments,
      status: data.dig("fields", "status", "name"),
      priority: data.dig("fields", "priority", "name"),
      assignee: data.dig("fields", "assignee", "displayName"),
      issue_type: data.dig("fields", "issuetype", "name"),
      formatted_title: "#{data['key']}: #{data.dig('fields', 'summary')}"
    }
  rescue StandardError => e
    Rails.logger.error("Error parsing JIRA response: #{e.message}")
    raise JiraError, "Failed to parse ticket data"
  end

  def extract_description(data)
    description_field = data.dig("fields", "description")
    extract_field_value(description_field)
  end

  def extract_attachments(data)
    attachments = data.dig("fields", "attachment") || []
    
    attachments.map do |attachment|
      {
        id: attachment["id"],
        filename: attachment["filename"],
        mime_type: attachment["mimeType"],
        size: attachment["size"],
        url: attachment["content"],
        thumbnail: attachment.dig("thumbnail"),
        is_image: image_file?(attachment["filename"])
      }
    end
  rescue StandardError => e
    Rails.logger.error "Error extracting attachments: #{e.message}"
    []
  end

  def extract_field_value(field_value)
    return nil if field_value.blank?
    
    # JIRA API v3 returns fields in Atlassian Document Format (ADF)
    # which is a JSON structure. We need to convert it to HTML.
    if field_value.is_a?(Hash)
      extract_html_from_adf(field_value)
    else
      ActionController::Base.helpers.sanitize(field_value.to_s)
    end
  end

  def extract_html_from_adf(adf_content)
    return "" unless adf_content.is_a?(Hash)
    
    content = adf_content["content"] || []
    
    html_parts = content.map do |node|
      extract_html_from_node(node)
    end
    
    html_parts.join("\n")
  end

  def extract_html_from_node(node)
    return "" unless node.is_a?(Hash)
    
    case node["type"]
    when "paragraph"
      content = node["content"] || []
      text = content.map { |n| extract_html_from_node(n) }.join
      text.present? ? "<p>#{text}</p>" : ""
      
    when "heading"
      level = node.dig("attrs", "level") || 1
      content = node["content"] || []
      text = content.map { |n| extract_html_from_node(n) }.join
      "<h#{level}>#{text}</h#{level}>"
      
    when "text"
      text = ActionController::Base.helpers.sanitize(node["text"] || "")
      # Handle text marks (bold, italic, etc.)
      marks = node["marks"] || []
      marks.each do |mark|
        case mark["type"]
        when "strong"
          text = "<strong>#{text}</strong>"
        when "em"
          text = "<em>#{text}</em>"
        when "code"
          text = "<code>#{text}</code>"
        when "underline"
          text = "<u>#{text}</u>"
        when "strike"
          text = "<s>#{text}</s>"
        end
      end
      text
      
    when "bulletList"
      items = node["content"] || []
      items_html = items.map { |item| extract_html_from_node(item) }.join
      "<ul>#{items_html}</ul>"
      
    when "orderedList"
      items = node["content"] || []
      items_html = items.map { |item| extract_html_from_node(item) }.join
      "<ol>#{items_html}</ol>"
      
    when "listItem"
      content = node["content"] || []
      content_html = content.map { |n| extract_html_from_node(n) }.join
      "<li>#{content_html}</li>"
      
    when "codeBlock"
      content = node["content"] || []
      code = content.map { |n| extract_html_from_node(n) }.join
      language = node.dig("attrs", "language") || ""
      "<pre><code class='language-#{language}'>#{ActionController::Base.helpers.sanitize(code)}</code></pre>"
      
    when "blockquote"
      content = node["content"] || []
      content_html = content.map { |n| extract_html_from_node(n) }.join
      "<blockquote>#{content_html}</blockquote>"
      
    when "hardBreak"
      "<br>"
      
    when "rule"
      "<hr>"
      
    when "media"
      # Handle JIRA images and media
      extract_media_html(node)
      
    when "mediaGroup"
      # Handle groups of media (like image galleries)
      content = node["content"] || []
      media_html = content.map { |n| extract_html_from_node(n) }.join
      "<div class='media-group'>#{media_html}</div>"
      
    when "mediaSingle"
      # Handle single media items
      content = node["content"] || []
      media_html = content.map { |n| extract_html_from_node(n) }.join
      "<div class='media-single'>#{media_html}</div>"
      
    else
      # Recursively handle nested content for unknown types
      content = node["content"] || []
      content.map { |n| extract_html_from_node(n) }.join
    end
  end

  def extract_media_html(node)
    attrs = node["attrs"] || {}
    media_type = attrs["type"]
    media_id = attrs["id"]
    
    case media_type
    when "file"
      # Handle file attachments
      file_name = attrs["collection"] || "attachment"
      file_url = "#{@base_url}/secure/attachment/#{media_id}/#{file_name}"
      
      # Check if it's an image by file extension
      if image_file?(file_name)
        alt_text = attrs["alt"] || "JIRA Image"
        "<div class='jira-image-container'><img src='#{file_url}' alt='#{alt_text}' class='jira-image' loading='lazy' /></div>"
      else
        # Non-image file
        "<div class='jira-attachment'><a href='#{file_url}' target='_blank' class='attachment-link'>📎 #{file_name}</a></div>"
      end
      
    when "external"
      # Handle external media URLs
      url = attrs["url"]
      if url && image_url?(url)
        alt_text = attrs["alt"] || "External Image"
        "<div class='jira-image-container'><img src='#{url}' alt='#{alt_text}' class='jira-image' loading='lazy' /></div>"
      else
        "<div class='jira-external-media'><a href='#{url}' target='_blank'>🔗 External Media</a></div>"
      end
      
    else
      # Fallback for unknown media types
      "<div class='jira-media-unknown'>[Media: #{media_type}]</div>"
    end
  rescue StandardError => e
    Rails.logger.error "Error extracting media HTML: #{e.message}"
    "<div class='jira-media-error'>[Error loading media]</div>"
  end

  def image_file?(filename)
    return false if filename.blank?
    filename.downcase.match?(/\.(jpg|jpeg|png|gif|webp|svg|bmp)$/)
  end

  def image_url?(url)
    return false if url.blank?
    url.downcase.match?(/\.(jpg|jpeg|png|gif|webp|svg|bmp)(\?|$)/)
  end

  def parse_description_sections(description)
    return { description: description } if description.blank?
    
    sections = {
      description: "",
      acceptance_criteria: nil,
      technical_writeup: nil
    }
    
    # Common section headers (case-insensitive)
    # Look for both HTML headers and markdown headers
    ac_pattern = /(?:<h[1-6]>.*?(?:acceptance criteria|ac|acceptance).*?<\/h[1-6]>|^##\s*(?:acceptance criteria|ac|acceptance))\s*\n?(.*?)(?=<h[1-6]>|^##|$)/mi
    tech_pattern = /(?:<h[1-6]>.*?(?:technical writeup|technical details|tech writeup|implementation|technical notes).*?<\/h[1-6]>|^##\s*(?:technical writeup|technical details|tech writeup|implementation|technical notes))\s*\n?(.*?)(?=<h[1-6]>|^##|$)/mi
    
    # Extract sections using regex matches with captured groups
    if description =~ ac_pattern
      match = description.match(ac_pattern)
      sections[:description] = description[0...match.begin(0)].strip
      sections[:acceptance_criteria] = match[1].strip if match[1].present?
      
      # Check for technical writeup after acceptance criteria
      remaining = description[match.end(0)..-1]
      if remaining =~ tech_pattern
        tech_match = remaining.match(tech_pattern)
        sections[:technical_writeup] = tech_match[1].strip if tech_match[1].present?
      end
    elsif description =~ tech_pattern
      # No AC section, but has technical writeup
      match = description.match(tech_pattern)
      sections[:description] = description[0...match.begin(0)].strip
      sections[:technical_writeup] = match[1].strip if match[1].present?
    else
      # No sections found, everything is description
      sections[:description] = description.strip
    end
    
    sections
  end

  def handle_error_response(response)
    case response.code
    when 401
      raise JiraError, "Authentication failed. Please check your JIRA credentials."
    when 404
      raise JiraError, "Ticket not found. Please check the ticket key or URL."
    when 403
      raise JiraError, "Access denied. You don't have permission to view this ticket."
    else
      raise JiraError, "JIRA API error (#{response.code}): #{response.message}"
    end
  end
end