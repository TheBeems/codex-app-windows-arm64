@{
    StoreSource = @{
        ExpectedIdentityName = "OpenAI.Codex"
        ExpectedArchitecture = "x64"
        ExpectedPublisher = "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B"
        RequiredSignerIssuerContains = "Microsoft Marketplace CA"
        AllowedUrlHosts = @(
            "tlu.dl.delivery.mp.microsoft.com"
        )
    }

    CodexReleaseTag = "rust-v0.137.0"
    RipgrepReleaseTag = "15.1.0"

    AssetHashes = @{
        "electron-v42.1.0-win32-arm64.zip" = "78A6BC7D1648383D72A79C95748E6BBC0FAAE412F11F29B987EE9DEDA605535E"
        "node-v24.14.0-win-arm64.zip" = "88D36E8109736A2FA9BDC596F2CF507A3C52C69CDF96E54F8ACD473EC14BE853"
        "codex-aarch64-pc-windows-msvc.exe" = "446D1FD44B07D05666DC8FBFB3222D0E896C68255249E16A722BC6D9EE2E2F05"
        "codex-command-runner-aarch64-pc-windows-msvc.exe" = "212CF84DD9670642A63AC088B65C330C4D137AF396A9609156F871174DA18C0B"
        "codex-windows-sandbox-setup-aarch64-pc-windows-msvc.exe" = "C3395550B57D7E7F2C540D1109510C98AA37B2A500E8B279288934F1D074E4E7"
        "codex-aarch64-unknown-linux-musl.tar.gz" = "1B9CAE96E27F5DA2752054A5BBA9204D486939EA60C65DF4BA4A638458734BDA"
        "bwrap-aarch64-unknown-linux-musl.tar.gz" = "6C83DF31A117226E6CC50783B7BC2EFD8805FE30B9E39B14F29CBC467FA8A910"
        "ripgrep-15.1.0-aarch64-pc-windows-msvc.zip" = "00D931FB5237C9696CA49308818EDB76D8EB6FC132761CB2A1BD616B2DF02F8E"
    }

    NativePackages = @{
        NodeHid = "3.3.0"
        SerialPortBindingsCpp = "12.0.1"
    }
}
