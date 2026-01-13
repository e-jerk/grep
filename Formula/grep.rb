class Grep < Formula
  desc "GPU-accelerated grep utility using Metal and Vulkan"
  homepage "https://github.com/e-jerk/grep"
  version "0.1.0"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/grep/releases/download/v#{version}/grep-macos-arm64-v#{version}.tar.gz"
      sha256 "45f27856075aa4f7996b05da81a2d4a8190db40865f2486a09d95fe2e6fe8b41" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/grep/releases/download/v#{version}/grep-linux-arm64-v#{version}.tar.gz"
      sha256 "be4e4ba2c39885ac120b7093bd37b84c0a218d5354752d0223e2c073c3ed015d" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/grep/releases/download/v#{version}/grep-linux-amd64-v#{version}.tar.gz"
      sha256 "b31355b03d267248871d22c2ebe7b42de83c0585c9c844d18525c5136b414b16" # linux-amd64
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
