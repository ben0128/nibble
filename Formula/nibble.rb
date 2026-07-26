class Nibble < Formula
  desc "Lightweight, zero-dependency Logitech mouse control for macOS"
  homepage "https://github.com/ben0128/nibble"
  url "https://github.com/ben0128/nibble/archive/refs/tags/v1.4.0.tar.gz"
  sha256 "dd745f735c65086ad0f4868d1003a850fa37847bdeb43978253df47d411b6c63"
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
