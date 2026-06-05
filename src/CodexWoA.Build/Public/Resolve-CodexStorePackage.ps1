function Resolve-CodexStorePackage {
    [CmdletBinding()]
    param(
        [string]$ProductId = "9PLM9XGG6VKS",
        [string]$Ring = "Retail",
        [string]$Lang = "en-US"
    )

    Resolve-LatestStoreMsix -ProductId $ProductId -Ring $Ring -Lang $Lang
}
