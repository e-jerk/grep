class GrepGnu < Formula
  desc "GPU-accelerated grep with all backends (Metal + Vulkan on macOS, Vulkan on Linux)"
  homepage "https://github.com/e-jerk/grep"
  version "0.1.0"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/grep/releases/download/v#{version}/grep-gnu-macos-arm64-v#{version}.tar.gz"
      sha256 "PLACEHOLDER_SHA256_MACOS_ARM64" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/grep/releases/download/v#{version}/grep-gnu-linux-arm64-v#{version}.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_ARM64" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/grep/releases/download/v#{version}/grep-gnu-linux-amd64-v#{version}.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_AMD64" # linux-amd64
    end
    depends_on "vulkan-loader"
  end

  depends_on "molten-vk" => :recommended if OS.mac?

  def install
    bin.install "grep"
  end

  test do
    system "#{bin}/grep", "--help"
  end
end
