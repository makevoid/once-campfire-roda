# frozen_string_literal: true
# Adapted from Campfire, MIT, copyright 37signals, LLC.
require_relative "test_helper"
require "vips"
require "tempfile"

# libvips selects a loader from a file's actual bytes, not from its declared content type. These
# tests pin which loader is selected for each file type under the app's configured loader policy
# (Campfire::Media).
class VipsLoaderPolicyTest < Minitest::Test
  # Header bytes are enough for libvips to identify a format; native types are encoded live, exotic
  # ones are represented by their magic bytes.
  FTYP_AVIF = "\x00\x00\x00\x1cftypavif\x00\x00\x00\x00avifmif1miaf".b
  FTYP_HEIC = "\x00\x00\x00\x1cftypheic\x00\x00\x00\x00heicmif1miaf".b
  def test_loads_png
    assert_equal "VipsForeignLoadPngFile", loader_for(encode("png"))
  end

  def test_loads_gif
    assert_equal "VipsForeignLoadNsgifFile", loader_for(encode("gif"))
  end

  def test_loads_jpeg
    assert_equal "VipsForeignLoadJpegFile", loader_for(encode("jpg"))
  end

  def test_loads_tiff
    assert_equal "VipsForeignLoadTiffFile", loader_for(encode("tif"))
  end

  def test_loads_webp
    assert_equal "VipsForeignLoadWebpFile", loader_for(encode("webp"))
  end

  def test_loads_avif
    assert_equal "VipsForeignLoadHeifFile", loader_for(FTYP_AVIF)
  end

  def test_loads_heic
    assert_equal "VipsForeignLoadHeifFile", loader_for(FTYP_HEIC)
  end

  def test_blocks_bmp_through_magickload
    assert_loader_blocked :magickload, ".bmp"
  end

  def test_blocks_psd_through_magickload
    assert_loader_blocked :magickload, ".psd"
  end

  def test_blocks_ico_through_magickload
    assert_loader_blocked :magickload, ".ico"
  end

  def test_blocks_svg_through_svgload
    assert_loader_blocked :svgload, ".svg"
  end

  def test_denies_openslide_files_through_openslideload
    # OpenSlide files can segfault the embedded sqlite in forked parallel workers
    assert_loader_blocked :openslideload, ".svs"
  end

  def test_denies_fits_files_through_fitsload
    assert_loader_blocked :fitsload, ".fits"
  end

  def test_denies_matlab_files_through_matload
    assert_loader_blocked :matload, ".mat"
  end

  def test_denies_nifti_files_through_niftiload
    assert_loader_blocked :niftiload, ".nii"
  end

  def test_denies_raw_files_through_dcrawload
    assert_loader_blocked :dcrawload, ".raw"
  end

  def test_denies_vips_files_through_vipsload
    assert_loader_blocked :vipsload, ".vips"
  end

  private
    # Invoke a specific libvips loader directly and assert it is refused because the
    # operation is blocked (rather than because the bytes are not a valid image).
    def assert_loader_blocked(operation, extension)
      Tempfile.create([ "blocked_loader", extension ], binmode: true) do |file|
        file.write "not an image"
        file.flush

        error = assert_raises(Vips::Error) { Vips::Image.public_send(operation, file.path) }
        actual = error.message.chomp

        # note that exception message may include multiple errors on separate lines,
        # so `^` and `$` anchors are used instead of `\A` and `\z`.
        if actual =~ /^VipsOperation: class \"#{operation}\" not found$/
          skip "libvips does not support #{operation} on this system"
        end
        assert_match(/^#{operation}: operation is blocked$/, actual)
      end
    end

    def encode(ext)
      Vips::Image.black(8, 8).add(128).cast("uchar").write_to_buffer(".#{ext}")
    end

    def loader_for(bytes)
      Tempfile.create(%w[loader_probe .img], binmode: true) do |file|
        file.write bytes
        file.flush
        Vips.vips_foreign_find_load(file.path)
      end
    end
end
