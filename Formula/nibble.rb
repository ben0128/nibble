class Nibble < Formula
  desc "Lightweight, zero-dependency Logitech mouse control for macOS"
  homepage "https://github.com/ben0128/nibble"
  url "https://github.com/ben0128/nibble/archive/refs/tags/v1.6.0.tar.gz"
  sha256 "3a8a64328f941baa5753660a0000e4faecb344e3a93c90c8925f4b343f9d79cb"
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
