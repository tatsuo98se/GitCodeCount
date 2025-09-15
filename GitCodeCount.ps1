# param (
#     [Parameter(Mandatory = $true)]
#     [string]$Revision1,
#     [Parameter(Mandatory = $true)]
#     [string]$Revision2,
#     [Parameter(Mandatory = $true)]
#     [string]$WorkingDirectory
# )

function Invoke-ClocDiffJson {
    <#
    .SYNOPSIS
        cloc --diff --json (リビジョン1) (リビジョン2) を実行し、結果JSONをPowerShellオブジェクトで返す

    .DESCRIPTION
        - clocコマンドで2つのリビジョン間の差分をJSON形式で取得
        - 結果のJSON文字列をPowerShellオブジェクトに変換して返す

    .PARAMETER Revision1
        比較元のリビジョン

    .PARAMETER Revision2
        比較先のリビジョン

    .PARAMETER WorkingDirectory
        clocコマンドを実行するカレントディレクトリ

    .OUTPUTS
        cloc --diff --json の結果(JSON)をPowerShellオブジェクトとして返す

    .EXAMPLE
        $obj = Invoke-ClocDiffJson -Revision1 "abc123" -Revision2 "def456" -WorkingDirectory "C:\MyRepo"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Revision1,
        [Parameter(Mandatory = $true)]
        [string]$Revision2,
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    try {
        $clocExe = "cloc"
        $arguments = "--diff --json $Revision1 $Revision2"
        $result = Invoke-ExternalProgram -ProgramPath $clocExe -Arguments $arguments -WorkingDirectory $WorkingDirectory
        if ($result.ExitCode -ne 0) {
            Write-Error "clocコマンドの実行に失敗しました: $($result.StdErr)"
            return $null
        }
        $json = $result.StdOut
        if ([string]::IsNullOrWhiteSpace($json)) {
            Write-Error "clocコマンドの出力が空です"
            return $null
        }
        $obj = $null
        try {
            $obj = $json | ConvertFrom-Json -AsHashtable
        }
        catch {
            Write-Error "cloc出力のJSON変換に失敗しました: $_"
            return $null
        }
        return $obj
    }
    catch {
        Write-Error "cloc差分取得時にエラーが発生しました: $_"
        return $null
    }
}

function Get-GitBranchNames {
    <#
    .SYNOPSIS
        指定したgitリポジトリのリモートブランチ名とリビジョン番号（コミットハッシュ）のペアを列挙し、配列として返す

    .DESCRIPTION
        - gitコマンドを使用してリモートブランチ名とリビジョン番号を取得
        - 返り値は@{ BranchName = <string>; Revision = <string> } の配列

    .PARAMETER RepositoryPath
        対象のgitリポジトリのパス

    .OUTPUTS
        [pscustomobject[]] BranchNameとRevisionのペアの配列

    .EXAMPLE
        $branches = Get-GitRemoteBranchNames -RepositoryPath "C:\MyRepo"
        foreach ($b in $branches) { $b.BranchName; $b.Revision }
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    try {
        $dict = @{}
        $refs = "refs/heads/", "refs/remotes/"

        foreach ($ref in $refs) {

            $gitExe = "git"
            $arguments1 = "for-each-ref --format='%(refname:short)' $ref"
            $arguments2 = "for-each-ref --format='%(objectname)' $ref"
            $result1 = Invoke-ExternalProgram -ProgramPath $gitExe -Arguments $arguments1 -WorkingDirectory $RepositoryPath
            if ($result1.ExitCode -ne 0 ) {
                Write-Error "gitコマンドの実行に失敗しました: $($result1.StdErr)"
                return @{}
            }
            $result2 = Invoke-ExternalProgram -ProgramPath $gitExe -Arguments $arguments2 -WorkingDirectory $RepositoryPath
            if ($result2.ExitCode -ne 0 ) {
                Write-Error "gitコマンドの実行に失敗しました: $($result2.StdErr)"
                return @{}
            }
            if ($result1.Count -ne $result2.Count) {
                Write-Error "取得したブランチ名とリビジョン番号の数が一致しません"
                return @{}
            }
            $branchNames = $result1.StdOut -split "`r?`n" | % { $_.Trim().Trim("'") } | Where-Object { $_ -ne "" } 
            $revisions = $result2.StdOut -split "`r?`n"  | % { $_.Trim().Trim("'") } | Where-Object { $_ -ne "" } 
            for ($i = 0; $i -lt $branchNames.Count; $i++) {
                # 例: origin/main 0123456789abcdef...
                if ($branchNames[$i] -eq "origin") { continue } # origin/HEAD は無視
                $dict[$branchNames[$i]] = $revisions[$i]
            }
        }        
        return $dict
    }
    catch {
        Write-Error "リモートブランチ取得時にエラーが発生しました: $_"
        return @{}
    }
}

function Write-CsvLine {
    <#
    .SYNOPSIS
        CSVファイルに1行書き込みする関数

    .DESCRIPTION
        - 文字列配列をCSVの1行として書き込む
        - 新規書き込み/追記を選択可能
        - 指定したエンコーディングで書き込み可能

    .PARAMETER FilePath
        書き込み先のCSVファイルのパス

    .PARAMETER Data
        CSVの1行に相当する文字列の配列

    .PARAMETER IsNewFile
        $true = 新規作成（既存ファイルを上書き）
        $false = 追記

    .PARAMETER Encoding
        書き込み時のエンコーディング (例: UTF8, Default, ASCII)

    .EXAMPLE
        Write-CsvLine -FilePath "C:\temp\test.csv" -Data @("AAA","B,B","CCC") -IsNewFile $true -Encoding UTF8

    .EXAMPLE
        Write-CsvLine -FilePath "C:\temp\test.csv" -Data @("111","222","33""3") -IsNewFile $false -Encoding Default
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Data,

        [Parameter(Mandatory = $true)]
        [bool]$IsNewFile,

        [Parameter(Mandatory = $true)]
        [string]$Encoding
    )

    try {
        # 配列をCSV形式の1行に変換（必要に応じてダブルクォートで囲む）
        $line = ($Data | ForEach-Object {
                if ($_ -match '[",\r\n]') {
                    '"' + ($_ -replace '"', '""') + '"'
                }
                else {
                    $_
                }
            }) -join ','

        # 新規作成か追加かで処理を分ける
        if ($IsNewFile -eq $true) {
            # 新規作成（既存ファイルは上書き）
            Set-Content -Path $FilePath -Value $line -Encoding $Encoding
        }
        else {
            # 追加書き込み
            Add-Content -Path $FilePath -Value $line -Encoding $Encoding
        }
    }
    catch {
        Write-Error "エラーが発生しました: $_"
    }
}

function Invoke-ExternalProgram {
    <#
    .SYNOPSIS
        外部プログラムを実行し、標準出力と標準エラーを取得する

    .DESCRIPTION
        - 指定した実行ファイルを呼び出し、その出力（stdout / stderr）を取得する
        - PowerShell 5.1 で動作確認可能な構文で作成
        - 出力はオブジェクトとして返却
        - 指定したカレントパス（作業ディレクトリ）で実行

    .PARAMETER ProgramPath
        実行するプログラムのパス（例: "C:\Windows\System32\ipconfig.exe"）

    .PARAMETER Arguments
        プログラムに渡す引数（例: "/all"）
        省略可能

    .PARAMETER WorkingDirectory
        プログラムを実行するカレントパス（作業ディレクトリ）。省略時は現在のディレクトリ。

    .OUTPUTS
        [pscustomobject] 標準出力と標準エラーを含むオブジェクト
        - StdOut : 標準出力の文字列
        - StdErr : 標準エラーの文字列
        - ExitCode : プロセスの終了コード

    .EXAMPLE
        $result = Invoke-ExternalProgram -ProgramPath "ping.exe" -Arguments "localhost" -WorkingDirectory "C:\Temp"
        $result.StdOut
        $result.StdErr
        $result.ExitCode
    #>

    param (
        [Parameter(Mandatory = $true)]
        [string]$ProgramPath,

        [Parameter(Mandatory = $false)]
        [string]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory
    )

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ProgramPath
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        if ($WorkingDirectory -and $WorkingDirectory.Trim() -ne "") {
            $psi.WorkingDirectory = $WorkingDirectory
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $process.Start() | Out-Null

        $stdOut = $process.StandardOutput.ReadToEnd()
        $stdErr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            Write-Error "外部プログラムの実行に失敗しました: $stdErr"
        }

        return [pscustomobject]@{
            StdOut   = $stdOut
            StdErr   = $stdErr
            ExitCode = $process.ExitCode
        }
    }
    catch {
        Write-Error "外部プログラム実行時にエラーが発生しました: $_"
    }
}

function WriteCsv {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$JsonObject

        # [Parameter(Mandatory = $true)]
        # [string]$outFile,

        # [Parameter(Mandatory = $true)]
        # [string]$Encoding
    )
    foreach ($categorys in $JsonObject.GetEnumerator()) {
        if ($categorys.Key -eq "header" -or $categorys.Key -eq "SUM") {
            continue
        }
        foreach ($language in $categorys.Value.GetEnumerator()) {
            $fields = @(
                $categorys.Key
                $language.Key
                $language.Value.nFiles
                $language.Value.blank
                $language.Value.comment
                $language.Value.code
            )
            Write-Output ($fields -join ",")
            # WriteCsvLine -FilePath $outFile -Data $fields -IsNewFile $false -Encoding $Encoding
        }
    }


}

$repoPath = "../3d_led_cube2"
$repos = Get-GitBranchNames -RepositoryPath $repoPath
$baseBranch = "origin/master"
$filterOption = "remote"

$baseRev = $repos[$baseBranch]
if ($baseRev -eq $null) {
    Write-Error "$baseBranch ブランチが存在しません"
    exit 1
}
if ($remotesOption -eq "remote" -and -not $baseBranch.StartsWith("origin/")) {
    Write-Error "ベースブランチがリモートブランチではありません"
    exit 1
}
$repos.Remove($baseBranch)

foreach ($branch in $repos.GetEnumerator()) {
    $name = $branch.Key
    $rev = $branch.Value
    Write-Output "$name : $rev"

    if ($remotesOption -eq "remote" -and -not $name.StartsWith("origin/")) {
        Write-Output "  (リモートブランチ以外なのでスキップ)"
        continue
    }

    if ($baseRev -eq $rev) {
        Write-Output "  (ベースブランチと同じリビジョンなのでスキップ)"
        continue
    }

    $results = Invoke-ClocDiffJson  -Revision1 $baseRev -Revision2 $rev -WorkingDirectory $repoPath
    if ($results -ne $null) {
        WriteCsv -JsonObject $results
    }
}

#Invoke-ExternalProgram -ProgramPath "git" -Arguments "for-each-ref --format='%(refname:short) %(objectname)' refs/remotes/" -WorkingDirectory "../3d_led_cube2"