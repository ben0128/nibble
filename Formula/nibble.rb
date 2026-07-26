class Nibble < Formula
  desc "Lightweight, zero-dependency Logitech mouse control for macOS"
  homepage "https://github.com/ben0128/nibble"
  url "https://github.com/ben0128/nibble/archive/refs/tags/v1.0.0.tar.gz"
  license "MIT"
  head "https://github.com/ben0128/nibble.git", branch: "main"

  depends_on :macos
  depends_on xcode: :build

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
