# frozen_string_literal: true
require_relative "test_helper"

class MediaAndTransferTest < CampfireTest
  def image_upload
    path = File.join(@directory, "avatar.png")
    Vips::Image.black(800, 400).write_to_file(path)
    Rack::Test::UploadedFile.new(path, "image/png")
  end

  def test_avatar_upload_variant_fallback_invalid_signature_and_removal
    sign_in(member)
    token = container.tokens.generate(member.id, purpose: :avatar)
    get "/users/#{token}/avatar"
    assert_equal 200, last_response.status
    assert_includes last_response.body, ">M</text>"
    mutate(:patch, "/users/me/profile", {user: {avatar: image_upload}})
    assert_equal 302, last_response.status
    assert_equal "Member", repo.user(member.id)[:name]
    get "/users/#{token}/avatar"
    assert_equal 200, last_response.status
    assert_equal "image/webp", last_response.content_type
    image = Vips::Image.new_from_buffer(last_response.body, "")
    assert_equal [512, 256], [image.width, image.height]
    get "/users/not-valid/avatar"
    assert_equal 404, last_response.status
    mutate(:delete, "/users/me/avatar")
    assert_equal 302, last_response.status
    get "/users/#{token}/avatar"
    assert_includes last_response.body, ">M</text>"
  end

  def test_logo_is_public_variants_are_bounded_and_changes_require_admin
    get "/account/logo?size=small"
    assert_equal 200, last_response.status
    assert_equal "image/png", last_response.content_type
    sign_in
    mutate(:put, "/account", {account: {logo: image_upload}})
    assert_equal 302, last_response.status
    get "/account/logo?size=small"
    image = Vips::Image.new_from_buffer(last_response.body, "")
    assert_equal [192, 96], [image.width, image.height]
    sign_in(member)
    mutate(:delete, "/account/logo")
    assert_equal 403, last_response.status
    refute_nil container.media.find("Account", repo.account[:id], "logo")
    sign_in
    mutate(:delete, "/account/logo")
    assert_equal 302, last_response.status
    assert_nil container.media.find("Account", repo.account[:id], "logo")
  end

  def test_member_can_read_account_and_css_but_cannot_change_them
    sign_in
    css = "body { background: #abc; }"
    mutate(:patch, "/account/custom_styles", {account: {custom_styles: css}})
    assert_equal 302, last_response.status
    mutate(:put, "/account", {account: {settings: {restrict_room_creation_to_administrators: "true"}}})
    assert_equal true, JSON.parse(repo.account[:settings]).fetch("restrict_room_creation_to_administrators")
    sign_in(member)
    get "/account/edit"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'action="/account/join_code"'
    get "/account/custom_styles.css"
    assert_equal css, last_response.body
    assert_equal "text/css; charset=utf-8", last_response.content_type
    mutate(:patch, "/account/custom_styles", {account: {custom_styles: "bad"}})
    assert_equal 403, last_response.status
    assert_equal css, repo.account[:custom_styles]
  end

  def test_transfer_requires_valid_unexpired_purpose_bound_token_and_same_origin
    token = container.tokens.generate(member.id, purpose: :transfer, expires_in: 14_400)
    get "/session/transfers/#{token}"
    assert_equal 200, last_response.status
    @csrf = csrf_from_response
    mutate(:put, "/session/transfers/#{token}", {}, csrf: false)
    assert_equal 422, last_response.status
    get "/session/transfers/#{token}"
    @csrf = csrf_from_response
    mutate(:put, "/session/transfers/#{token}")
    assert_equal 302, last_response.status
    assert_equal member.id, db[:sessions].order(:id).last[:user_id]
    get "/rooms/#{room.id}"
    assert_equal 200, last_response.status
    @csrf = csrf_from_response
    wrong_purpose = container.tokens.generate(admin.id, purpose: :avatar)
    mutate(:put, "/session/transfers/#{wrong_purpose}")
    assert_equal 400, last_response.status
    expired = container.tokens.generate(admin.id, purpose: :transfer, expires_in: 10, now: Time.now.to_i - 11)
    mutate(:put, "/session/transfers/#{expired}")
    assert_equal 400, last_response.status
    db[:users].where(id: admin.id).update(status: 1)
    deactivated = container.tokens.generate(admin.id, purpose: :transfer, expires_in: 100)
    mutate(:put, "/session/transfers/#{deactivated}")
    assert_equal 400, last_response.status
    assert_equal 1, db[:sessions].count
  end

  def test_qr_code_and_token_tampering
    get "/qr_code/#{Base64.urlsafe_encode64('https://example.test/join/invite')}"
    assert_equal 200, last_response.status
    assert_equal "image/svg+xml", last_response.content_type
    assert_includes last_response.body, "<svg"
    signed = container.tokens.generate(member.id, purpose: :avatar)
    replacement = signed.sub(/--.*/, "--#{'0' * 64}")
    assert_nil container.tokens.verify(replacement, purpose: :avatar)
  end

  def test_image_attachment_preview_metadata_ranges_and_private_access
    private_room = service.create_room(admin, {"name" => "Files"}, type: "Rooms::Closed", user_ids: [member.id])
    upload = image_upload
    message = post_message(admin, private_room, "", attachment: {tempfile: upload.tempfile, filename: "wide.png"})
    file = db[:attachments][message_id: message[:id]]
    assert_equal({"width" => 800, "height" => 400}, JSON.parse(file[:metadata]))
    sign_in(member)
    get "/attachments/#{file[:id]}?variant=thumb"
    assert_equal "image/webp", last_response.content_type
    assert_equal 800, Vips::Image.new_from_buffer(last_response.body, "").width
    get "/attachments/#{file[:id]}?inline=1"
    complete = last_response.body
    etag = last_response["etag"]
    header "Range", "bytes=4-15"
    get "/attachments/#{file[:id]}?inline=1"
    assert_equal 206, last_response.status
    assert_equal complete.byteslice(4, 12), last_response.body
    assert_equal "bytes 4-15/#{complete.bytesize}", last_response["content-range"]
    header "Range", "bytes=-8"
    get "/attachments/#{file[:id]}?inline=1"
    assert_equal complete.byteslice(-8, 8), last_response.body
    header "Range", "bytes=#{complete.bytesize}-"
    get "/attachments/#{file[:id]}"
    assert_equal 416, last_response.status
    header "Range", "bytes=0-2"
    header "If-Range", '"stale"'
    get "/attachments/#{file[:id]}"
    assert_equal 200, last_response.status
    assert_equal complete, last_response.body
    header "Range", nil
    header "If-Range", nil
    header "If-None-Match", etag
    get "/attachments/#{file[:id]}"
    assert_equal 304, last_response.status
    header "If-None-Match", nil
    sign_in(outsider)
    get "/attachments/#{file[:id]}?variant=thumb"
    assert_equal 404, last_response.status
  end

  def test_video_metadata_preview_and_pdf_first_page_preview
    video = File.join(@directory, "clip.mp4")
    container.media.command("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=320x240:d=0.1", "-c:v", "libx264", "-pix_fmt", "yuv420p", video)
    File.open(video, "rb") do |file|
      message = post_message(admin, room, "", attachment: {tempfile: file, filename: "clip.mp4"})
      attachment = db[:attachments][message_id: message[:id]]
      metadata = JSON.parse(attachment[:metadata])
      assert_equal [320, 240], metadata.values_at("width", "height")
      assert_operator metadata["duration"], :>, 0
      preview, type = container.media.variant(attachment, :thumb)
      assert_equal "image/webp", type
      assert File.size(preview).positive?
    end
    # A tiny self-contained one-page PDF, generated without a PDF Ruby dependency.
    objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R >>", "<< /Length 0 >>\nstream\n\nendstream"]
    pdf, offsets = +"%PDF-1.4\n", [0]
    objects.each_with_index { |object, index| offsets << pdf.bytesize; pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n" }
    xref = pdf.bytesize
    pdf << "xref\n0 5\n0000000000 65535 f \n" << offsets.drop(1).map { |offset| "%010d 00000 n \n" % offset }.join
    pdf << "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    path = File.join(@directory, "page.pdf")
    File.binwrite(path, pdf)
    File.open(path, "rb") do |file|
      message = post_message(admin, room, "", attachment: {tempfile: file, filename: "page.pdf"})
      attachment = db[:attachments][message_id: message[:id]]
      assert_equal "application/pdf", attachment[:content_type]
      preview, type = container.media.variant(attachment, :thumb)
      assert_equal "image/webp", type
      assert File.size(preview).positive?
    end
  end
end
