class Nibble < Formula
  desc "Lightweight, zero-dependency Logitech mouse control for macOS"
  homepage "https://github.com/ben0128/nibble"
  url "https://github.com/ben0128/nibble/archive/refs/tags/v1.7.1.tar.gz"
  sha256 "fe11b090ad2ea0f7c5cdbdd0c65e00a06d6e9eb47a68238390a87a0bd620ca6b"
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

      This formula installs the CLI only. The menu bar app bundle —
      low-battery notifications and "start at login" — needs a source
      build:
        git clone https://github.com/ben0128/nibble && cd nibble
        make install-app
    EOS
  end

  test do
    assert_match "nibble", shell_output("#{bin}/nibble version")
  end
end
