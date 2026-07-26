class Nibble < Formula
  desc "Lightweight, zero-dependency Logitech mouse control for macOS"
  homepage "https://github.com/ben0128/nibble"
  url "https://github.com/ben0128/nibble/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "ed33aa7b4406949347da7c3e70a11c664ec6feecc15ae7399cfc5c53664d2862"
  license "MIT"
  head "https://github.com/ben0128/nibble.git", branch: "main"

  # builds with the Command Line Tools' swiftc — full Xcode not required
  depends_on :macos

  def install
    system "make"
    bin.install "nibble"
  end

  def caveats
    <<~EOS
      Grant Input Monitoring to your terminal before first run:
        System Settings > Privacy & Security > Input Monitoring

      Button remapping additionally needs Accessibility permission and
      the resident menu bar (`nibble menubar`).
    EOS
  end

  test do
    assert_match "nibble", shell_output("#{bin}/nibble version")
  end
end
