# frozen_string_literal: true

require "test_helper"

class JiraServiceAdfParserTest < ActiveSupport::TestCase
  # Test the ADF to HTML conversion without making actual API calls
  # We test the private methods by creating a testable subclass

  class TestableJiraService < JiraService
    def initialize
      # Skip credential validation for testing
    end

    # Expose private methods for testing
    def test_extract_html_from_node(node)
      extract_html_from_node(node)
    end

    def test_extract_html_from_adf(adf_content)
      extract_html_from_adf(adf_content)
    end
  end

  def setup
    @service = TestableJiraService.new
  end

  # ===================
  # Table Tests
  # ===================

  test "parses simple table with header and cells" do
    adf = {
      "type" => "table",
      "content" => [
        {
          "type" => "tableRow",
          "content" => [
            {
              "type" => "tableHeader",
              "content" => [
                { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Header 1" }] }
              ]
            },
            {
              "type" => "tableHeader",
              "content" => [
                { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Header 2" }] }
              ]
            }
          ]
        },
        {
          "type" => "tableRow",
          "content" => [
            {
              "type" => "tableCell",
              "content" => [
                { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Cell 1" }] }
              ]
            },
            {
              "type" => "tableCell",
              "content" => [
                { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Cell 2" }] }
              ]
            }
          ]
        }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-table-wrapper'>"
    assert_includes html, "<table class='adf-table'>"
    assert_includes html, "</table></div>"
    assert_includes html, "<tr>"
    assert_includes html, "<th>"
    assert_includes html, "Header 1"
    assert_includes html, "Header 2"
    assert_includes html, "<td>"
    assert_includes html, "Cell 1"
    assert_includes html, "Cell 2"
  end

  test "parses table cell with colspan" do
    adf = {
      "type" => "tableCell",
      "attrs" => { "colspan" => 2 },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Spanning cell" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "colspan='2'"
    assert_includes html, "Spanning cell"
  end

  test "parses table cell with rowspan" do
    adf = {
      "type" => "tableCell",
      "attrs" => { "rowspan" => 3 },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Tall cell" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "rowspan='3'"
    assert_includes html, "Tall cell"
  end

  test "parses table header with colspan and rowspan" do
    adf = {
      "type" => "tableHeader",
      "attrs" => { "colspan" => 2, "rowspan" => 2 },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Big header" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<th"
    assert_includes html, "colspan='2'"
    assert_includes html, "rowspan='2'"
    assert_includes html, "Big header"
  end

  test "parses empty table" do
    adf = {
      "type" => "table",
      "content" => []
    }

    html = @service.test_extract_html_from_node(adf)

    assert_equal "<div class='adf-table-wrapper'><table class='adf-table'></table></div>", html
  end

  test "parses tableRow" do
    adf = {
      "type" => "tableRow",
      "content" => [
        {
          "type" => "tableCell",
          "content" => [
            { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Cell" }] }
          ]
        }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<tr>"
    assert_includes html, "</tr>"
    assert_includes html, "Cell"
  end

  # ===================
  # Mark Tests
  # ===================

  test "parses link mark" do
    adf = {
      "type" => "text",
      "text" => "Click here",
      "marks" => [
        { "type" => "link", "attrs" => { "href" => "https://example.com" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<a href='https://example.com'"
    assert_includes html, "target='_blank'"
    assert_includes html, "rel='noopener'"
    assert_includes html, "Click here"
    assert_includes html, "</a>"
  end

  test "parses link mark with nested formatting" do
    adf = {
      "type" => "text",
      "text" => "Bold link",
      "marks" => [
        { "type" => "strong" },
        { "type" => "link", "attrs" => { "href" => "https://example.com" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<strong>"
    assert_includes html, "<a href='https://example.com'"
    assert_includes html, "Bold link"
  end

  test "parses textColor mark" do
    adf = {
      "type" => "text",
      "text" => "Red text",
      "marks" => [
        { "type" => "textColor", "attrs" => { "color" => "#ff0000" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "style='color:#ff0000'"
    assert_includes html, "Red text"
  end

  test "parses backgroundColor mark" do
    adf = {
      "type" => "text",
      "text" => "Highlighted",
      "marks" => [
        { "type" => "backgroundColor", "attrs" => { "color" => "#ffff00" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "style='background-color:#ffff00'"
    assert_includes html, "Highlighted"
  end

  test "parses subsup mark with subscript" do
    adf = {
      "type" => "text",
      "text" => "2",
      "marks" => [
        { "type" => "subsup", "attrs" => { "type" => "sub" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<sub>"
    assert_includes html, "2"
    assert_includes html, "</sub>"
  end

  test "parses subsup mark with superscript" do
    adf = {
      "type" => "text",
      "text" => "2",
      "marks" => [
        { "type" => "subsup", "attrs" => { "type" => "sup" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<sup>"
    assert_includes html, "2"
    assert_includes html, "</sup>"
  end

  # ===================
  # Panel Tests
  # ===================

  test "parses panel with info type" do
    adf = {
      "type" => "panel",
      "attrs" => { "panelType" => "info" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Info message" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-panel adf-panel-info'>"
    assert_includes html, "Info message"
    assert_includes html, "</div>"
  end

  test "parses panel with warning type" do
    adf = {
      "type" => "panel",
      "attrs" => { "panelType" => "warning" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Warning!" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-panel adf-panel-warning'>"
    assert_includes html, "Warning!"
  end

  test "parses panel with error type" do
    adf = {
      "type" => "panel",
      "attrs" => { "panelType" => "error" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Error occurred" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-panel adf-panel-error'>"
    assert_includes html, "Error occurred"
  end

  test "parses panel with success type" do
    adf = {
      "type" => "panel",
      "attrs" => { "panelType" => "success" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Success!" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-panel adf-panel-success'>"
    assert_includes html, "Success!"
  end

  test "parses panel with note type" do
    adf = {
      "type" => "panel",
      "attrs" => { "panelType" => "note" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Note this" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-panel adf-panel-note'>"
    assert_includes html, "Note this"
  end

  test "parses panel with default type when missing" do
    adf = {
      "type" => "panel",
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Default panel" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='adf-panel adf-panel-info'>"
    assert_includes html, "Default panel"
  end

  # ===================
  # Inline Node Tests
  # ===================

  test "parses mention node" do
    adf = {
      "type" => "mention",
      "attrs" => { "id" => "123", "text" => "@johndoe" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<span class='adf-mention'>"
    assert_includes html, "@johndoe"
    assert_includes html, "</span>"
  end

  test "parses mention node with default text" do
    adf = {
      "type" => "mention",
      "attrs" => { "id" => "123" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<span class='adf-mention'>"
    assert_includes html, "@user"
  end

  test "parses emoji node with text" do
    adf = {
      "type" => "emoji",
      "attrs" => { "shortName" => ":smile:", "text" => "😄" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<span class='adf-emoji'>"
    assert_includes html, "😄"
    assert_includes html, "</span>"
  end

  test "parses emoji node with shortName fallback" do
    adf = {
      "type" => "emoji",
      "attrs" => { "shortName" => ":thumbsup:" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<span class='adf-emoji'>"
    assert_includes html, ":thumbsup:"
  end

  test "parses status node" do
    adf = {
      "type" => "status",
      "attrs" => { "text" => "In Progress", "color" => "blue" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<span class='adf-status adf-status-blue'>"
    assert_includes html, "In Progress"
    assert_includes html, "</span>"
  end

  test "parses status node with default color" do
    adf = {
      "type" => "status",
      "attrs" => { "text" => "Unknown" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<span class='adf-status adf-status-neutral'>"
    assert_includes html, "Unknown"
  end

  test "parses date node" do
    adf = {
      "type" => "date",
      "attrs" => { "timestamp" => "1704067200000" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<time class='adf-date'"
    assert_includes html, "datetime='1704067200000'"
    assert_includes html, "Jan 01, 2024"
  end

  test "parses date node with missing timestamp" do
    adf = {
      "type" => "date",
      "attrs" => {}
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<time class='adf-date'"
  end

  test "parses inlineCard node" do
    adf = {
      "type" => "inlineCard",
      "attrs" => { "url" => "https://jira.example.com/browse/PROJ-123" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<a class='adf-inline-card'"
    assert_includes html, "href='https://jira.example.com/browse/PROJ-123'"
    assert_includes html, "target='_blank'"
    assert_includes html, "rel='noopener'"
  end

  test "parses inlineCard node with empty url" do
    adf = {
      "type" => "inlineCard",
      "attrs" => {}
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<a class='adf-inline-card'"
    assert_includes html, "href=''"
  end

  # ===================
  # Expand/Collapse Tests
  # ===================

  test "parses expand node" do
    adf = {
      "type" => "expand",
      "attrs" => { "title" => "Click to expand" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hidden content" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<details class='adf-expand'>"
    assert_includes html, "<summary>Click to expand</summary>"
    assert_includes html, "Hidden content"
    assert_includes html, "</details>"
  end

  test "parses expand node with default title" do
    adf = {
      "type" => "expand",
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Content" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<summary>Details</summary>"
  end

  test "parses nestedExpand node" do
    adf = {
      "type" => "nestedExpand",
      "attrs" => { "title" => "Nested section" },
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Nested content" }] }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<details class='adf-expand'>"
    assert_includes html, "<summary>Nested section</summary>"
    assert_includes html, "Nested content"
  end

  # ===================
  # Media Tests
  # ===================

  test "parses mediaSingle node" do
    adf = {
      "type" => "mediaSingle",
      "content" => [
        { "type" => "media", "attrs" => { "type" => "file", "id" => "123", "collection" => "screenshot.png" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='media-single'>"
    assert_includes html, "jira-image-container"
  end

  test "parses mediaGroup node" do
    adf = {
      "type" => "mediaGroup",
      "content" => [
        { "type" => "media", "attrs" => { "type" => "file", "id" => "123", "collection" => "img1.png" } },
        { "type" => "media", "attrs" => { "type" => "file", "id" => "456", "collection" => "img2.png" } }
      ]
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='media-group'>"
  end

  test "parses media node with file type as image using proxy" do
    adf = {
      "type" => "media",
      "attrs" => { "type" => "file", "id" => "123", "collection" => "screenshot.png", "alt" => "My image" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='jira-image-container'>"
    assert_includes html, "src='/jira_images/123'"
    assert_includes html, "alt='My image'"
  end

  test "parses media node with file type as non-image attachment" do
    adf = {
      "type" => "media",
      "attrs" => { "type" => "file", "id" => "456", "collection" => "document.pdf" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='jira-attachment'>"
    assert_includes html, "href='/jira_images/456'"
    assert_includes html, "document.pdf"
  end

  test "parses media node with external type" do
    adf = {
      "type" => "media",
      "attrs" => { "type" => "external", "url" => "https://example.com/image.png" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "<div class='jira-image-container'>"
    assert_includes html, "src='https://example.com/image.png'"
  end

  test "parses media node with unknown type falls back to proxy" do
    adf = {
      "type" => "media",
      "attrs" => { "id" => "789" }
    }

    html = @service.test_extract_html_from_node(adf)

    assert_includes html, "src='/jira_images/789'"
  end
end
