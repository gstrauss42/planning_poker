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
    
    # Include custom fields if configured
    fields_list = ["summary", "description", "status", "priority", "assignee", "issuetype", "attachment"]
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
    
    # Get attachments first so we can build UUID -> ID lookup for inline images
    attachments = extract_attachments(data)
    @attachment_lookup = build_attachment_lookup(attachments)
    
    # Get description (might be in different formats)
    raw_description = extract_description(data)
    
    # Parse sections from description
    sections = parse_description_sections(raw_description)
    
    # Try to get acceptance criteria from custom field if configured
    acceptance_criteria = if @acceptance_criteria_field.present?
      field_value = data.dig("fields", @acceptance_criteria_field)
      extract_field_value(field_value)
    else
      sections[:acceptance_criteria]
    end
    
    # Try to get technical writeup from custom field if configured
    technical_writeup = if @technical_writeup_field.present?
      field_value = data.dig("fields", @technical_writeup_field)
      extract_field_value(field_value)
    else
      sections[:technical_writeup]
    end
    
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
    # Try to use JIRA's pre-rendered HTML first (has working image URLs)
    rendered_description = data.dig("renderedFields", "description")
    if rendered_description.present?
      return sanitize_jira_html(rendered_description)
    end
    
    # Fall back to parsing ADF ourselves
    description_field = data.dig("fields", "description")
    extract_field_value(description_field)
  end

  def sanitize_jira_html(html)
    return nil if html.blank?
    
    # Rewrite JIRA image URLs to use our proxy
    processed_html = rewrite_jira_image_urls(html)
    
    # Sanitize but allow images, links, and common HTML
    allowed_tags = %w[p h1 h2 h3 h4 h5 h6 br hr ul ol li a img strong em code pre blockquote table tr td th thead tbody div span]
    allowed_attributes = {
      'a' => ['href', 'target', 'rel'],
      'img' => ['src', 'alt', 'class', 'style', 'width', 'height', 'loading'],
      'td' => ['colspan', 'rowspan'],
      'th' => ['colspan', 'rowspan'],
      'div' => ['class'],
      'span' => ['class', 'style']
    }
    
    ActionController::Base.helpers.sanitize(processed_html, tags: allowed_tags, attributes: allowed_attributes)
  end

  def rewrite_jira_image_urls(html)
    return html if html.blank?
    
    # Match JIRA attachment URLs and rewrite to use our proxy
    # Pattern: /rest/api/3/attachment/content/12345 or /secure/attachment/12345/filename.png
    html.gsub(%r{(?:https?://[^/]+)?/(?:rest/api/3/attachment/content|secure/attachment)/(\d+)(?:/[^"'>\s]*)?}i) do |_match|
      "/jira_images/#{$1}"
    end
  end

  def build_attachment_lookup(attachments)
    lookup = {}
    attachments.each do |att|
      # Map UUID (mediaApiFileId) to numeric ID
      if att[:media_api_file_id].present?
        lookup[att[:media_api_file_id]] = att[:id]
      end
      # Also map by filename as fallback
      if att[:filename].present?
        lookup[att[:filename]] = att[:id]
      end
    end
    lookup
  end

  def extract_attachments(data)
    attachments = data.dig("fields", "attachment") || []
    
    attachments.map do |attachment|
      content_url = attachment["content"]
      
      # Convert relative URL to absolute URL if needed
      if content_url && !content_url.start_with?("http")
        content_url = "#{@base_url}#{content_url}" unless content_url.start_with?("/")
        content_url = "#{@base_url}/#{content_url}" if content_url.start_with?("/")
      end
      
      {
        id: attachment["id"],
        media_api_file_id: attachment["mediaApiFileId"],  # UUID used in ADF media nodes
        filename: attachment["filename"],
        mime_type: attachment["mimeType"],
        size: attachment["size"],
        url: content_url,
        proxy_url: "/jira_images/#{attachment["id"]}",  # Proxy URL for authenticated access
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
        when "link"
          href = ActionController::Base.helpers.sanitize(mark.dig("attrs", "href") || "")
          text = "<a href='#{href}' target='_blank' rel='noopener'>#{text}</a>"
        when "textColor"
          color = ActionController::Base.helpers.sanitize(mark.dig("attrs", "color") || "")
          text = "<span style='color:#{color}'>#{text}</span>"
        when "backgroundColor"
          color = ActionController::Base.helpers.sanitize(mark.dig("attrs", "color") || "")
          text = "<span style='background-color:#{color}'>#{text}</span>"
        when "subsup"
          type = mark.dig("attrs", "type")
          tag = type == "sub" ? "sub" : "sup"
          text = "<#{tag}>#{text}</#{tag}>"
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
      language = normalize_language(node.dig("attrs", "language"))
      "<pre class='language-#{language}'><code class='language-#{language}'>#{ActionController::Base.helpers.sanitize(code)}</code></pre>"
      
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
      
    # Table support - wrap in scrollable container
    when "table"
      rows = node["content"] || []
      rows_html = rows.map { |row| extract_html_from_node(row) }.join
      "<div class='adf-table-wrapper'><table class='adf-table'>#{rows_html}</table></div>"

    when "tableRow"
      cells = node["content"] || []
      cells_html = cells.map { |cell| extract_html_from_node(cell) }.join
      "<tr>#{cells_html}</tr>"

    when "tableHeader"
      attrs = build_cell_attrs(node)
      content = node["content"] || []
      content_html = content.map { |n| extract_html_from_node(n) }.join
      "<th#{attrs}>#{content_html}</th>"

    when "tableCell"
      attrs = build_cell_attrs(node)
      content = node["content"] || []
      content_html = content.map { |n| extract_html_from_node(n) }.join
      "<td#{attrs}>#{content_html}</td>"

    # Panel support
    when "panel"
      panel_type = node.dig("attrs", "panelType") || "info"
      content = node["content"] || []
      content_html = content.map { |n| extract_html_from_node(n) }.join
      panel_header = panel_header_for_type(panel_type)
      "<div class='adf-panel adf-panel-#{panel_type}'>#{panel_header}#{content_html}</div>"

    # Inline nodes
    when "mention"
      name = node.dig("attrs", "text") || "@user"
      "<span class='adf-mention'>#{ActionController::Base.helpers.sanitize(name)}</span>"

    when "emoji"
      short_name = node.dig("attrs", "shortName") || ""
      text = node.dig("attrs", "text") || short_name
      "<span class='adf-emoji'>#{ActionController::Base.helpers.sanitize(text)}</span>"

    when "status"
      text = node.dig("attrs", "text") || ""
      color = node.dig("attrs", "color") || "neutral"
      "<span class='adf-status adf-status-#{color}'>#{ActionController::Base.helpers.sanitize(text)}</span>"

    when "date"
      timestamp = node.dig("attrs", "timestamp")
      formatted = timestamp ? Time.at(timestamp.to_i / 1000).strftime("%b %d, %Y") : ""
      "<time class='adf-date' datetime='#{timestamp}'>#{formatted}</time>"

    when "inlineCard"
      url = node.dig("attrs", "url") || ""
      "<a class='adf-inline-card' href='#{ActionController::Base.helpers.sanitize(url)}' target='_blank' rel='noopener'>#{ActionController::Base.helpers.sanitize(url)}</a>"

    # Expand/collapse support
    when "expand", "nestedExpand"
      title = node.dig("attrs", "title") || "Details"
      content = node["content"] || []
      content_html = content.map { |n| extract_html_from_node(n) }.join
      "<details class='adf-expand'><summary>#{ActionController::Base.helpers.sanitize(title)}</summary>#{content_html}</details>"

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
    # Use .presence to handle empty strings - collection is often "" which is truthy
    file_name = attrs["collection"].presence || attrs["alt"].presence || "attachment"
    
    # Look up numeric ID from UUID if available
    numeric_id = resolve_attachment_id(media_id, file_name)
    
    case media_type
    when "file"
      # Use proxy URL with numeric ID for authenticated JIRA images
      if numeric_id.present?
        proxy_url = "/jira_images/#{numeric_id}"
        
        # Check if it's an image by file extension
        if image_file?(file_name)
          alt_text = ActionController::Base.helpers.sanitize(attrs["alt"] || file_name)
          "<div class='jira-image-container'><img src='#{proxy_url}' alt='#{alt_text}' class='jira-image' loading='lazy' /><div class='image-caption'>#{alt_text}</div></div>"
        else
          # Non-image file - still use proxy for download
          "<div class='jira-attachment'><a href='#{proxy_url}' target='_blank' class='attachment-link'>📎 #{ActionController::Base.helpers.sanitize(file_name)}</a></div>"
        end
      else
        "<div class='jira-media-unknown'>[Attachment: #{ActionController::Base.helpers.sanitize(file_name)}]</div>"
      end
      
    when "external"
      # Handle external media URLs (no auth needed)
      url = attrs["url"]
      if url && image_url?(url)
        alt_text = ActionController::Base.helpers.sanitize(attrs["alt"] || "External Image")
        "<div class='jira-image-container'><img src='#{url}' alt='#{alt_text}' class='jira-image' loading='lazy' /></div>"
      else
        "<div class='jira-external-media'><a href='#{ActionController::Base.helpers.sanitize(url)}' target='_blank'>🔗 External Media</a></div>"
      end
      
    else
      # Fallback for unknown media types - try to resolve ID and use proxy
      if numeric_id.present?
        proxy_url = "/jira_images/#{numeric_id}"
        "<div class='jira-image-container'><img src='#{proxy_url}' alt='Media' class='jira-image' loading='lazy' /></div>"
      elsif media_id.present?
        # Last resort: try the original ID (might be numeric already)
        proxy_url = "/jira_images/#{media_id}"
        "<div class='jira-image-container'><img src='#{proxy_url}' alt='Media' class='jira-image' loading='lazy' onerror=\"this.parentElement.innerHTML='[Image not found]'\"/></div>"
      else
        "<div class='jira-media-unknown'>[Media: #{media_type || 'unknown'}]</div>"
      end
    end
  rescue StandardError => e
    Rails.logger.error "Error extracting media HTML: #{e.message}"
    "<div class='jira-media-error'>[Error loading media]</div>"
  end

  def resolve_attachment_id(media_id, file_name)
    return nil if media_id.blank? && file_name.blank?
    return media_id if media_id.present? && media_id.match?(/^\d+$/)  # Already numeric
    
    # Try to look up by UUID
    if @attachment_lookup && media_id.present?
      resolved = @attachment_lookup[media_id]
      return resolved if resolved.present?
    end
    
    # Try to look up by filename
    if @attachment_lookup && file_name.present?
      resolved = @attachment_lookup[file_name]
      return resolved if resolved.present?
    end
    
    nil
  end

  def image_file?(filename)
    return false if filename.blank?
    filename.downcase.match?(/\.(jpg|jpeg|png|gif|webp|svg|bmp)$/)
  end

  def image_url?(url)
    return false if url.blank?
    url.downcase.match?(/\.(jpg|jpeg|png|gif|webp|svg|bmp)(\?|$)/)
  end

  def normalize_language(lang)
    return "plaintext" if lang.blank?
    
    # Map JIRA language names to Prism.js language names
    mappings = {
      "sh" => "bash",
      "shell" => "bash",
      "yml" => "yaml",
      "js" => "javascript",
      "ts" => "typescript",
      "py" => "python",
      "rb" => "ruby",
      "erb" => "ruby",
      "html" => "markup",
      "xml" => "markup",
      "jsx" => "javascript",
      "tsx" => "typescript",
      "dockerfile" => "docker",
      "c#" => "csharp",
      "c++" => "cpp"
    }
    
    normalized = lang.downcase.strip
    mappings[normalized] || normalized
  end

  def parse_description_sections(description)
    return { description: description } if description.blank?
    
    sections = {
      description: "",
      acceptance_criteria: nil,
      technical_writeup: nil
    }
    
    # Common section headers (case-insensitive)
    # Look for headers in HTML or plain text
    ac_pattern = /<h[1-6]>.*?(acceptance criteria|ac|acceptance).*?<\/h[1-6]>|(?:^|\n)(?:acceptance criteria|ac|acceptance)\s*:?\s*\n/i
    tech_pattern = /<h[1-6]>.*?(technical writeup|technical details|tech writeup|implementation|technical notes).*?<\/h[1-6]>|(?:^|\n)(?:technical writeup|technical details|tech writeup|implementation|technical notes)\s*:?\s*\n/i
    
    # Split by acceptance criteria
    if description =~ ac_pattern
      parts = description.split(ac_pattern, 2)
      sections[:description] = parts[0].strip
      
      # Now split the rest by technical writeup
      remaining = parts[-1] # Get last part after split
      if remaining =~ tech_pattern
        ac_parts = remaining.split(tech_pattern, 2)
        sections[:acceptance_criteria] = ac_parts[0].strip
        sections[:technical_writeup] = ac_parts[-1].strip if ac_parts[-1].present?
      else
        sections[:acceptance_criteria] = remaining.strip
      end
    elsif description =~ tech_pattern
      # No AC section, but has technical writeup
      parts = description.split(tech_pattern, 2)
      sections[:description] = parts[0].strip
      sections[:technical_writeup] = parts[-1].strip if parts[-1].present?
    else
      # No sections found, everything is description
      sections[:description] = description.strip
    end
    
    sections
  end

  def panel_header_for_type(panel_type)
    icons_and_labels = {
      "info" => { icon: "ℹ️", label: "Info" },
      "note" => { icon: "📝", label: "Note" },
      "warning" => { icon: "⚠️", label: "Warning" },
      "error" => { icon: "❌", label: "Error" },
      "success" => { icon: "✅", label: "Success" }
    }
    config = icons_and_labels[panel_type] || icons_and_labels["info"]
    "<div class='adf-panel-header'><span class='adf-panel-icon'>#{config[:icon]}</span><span>#{config[:label]}</span></div>"
  end

  def build_cell_attrs(node)
    attrs = []
    colspan = node.dig("attrs", "colspan")
    rowspan = node.dig("attrs", "rowspan")
    attrs << "colspan='#{colspan}'" if colspan && colspan > 1
    attrs << "rowspan='#{rowspan}'" if rowspan && rowspan > 1
    attrs.empty? ? "" : " #{attrs.join(' ')}"
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