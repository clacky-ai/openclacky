<#
  Windows-side executor for the computer-use extension.

  The Ruby backend (running inside WSL) launches this through interop, so the
  process inherits whatever desktop session launched WSL — which is what makes
  screen capture and input injection land on the real desktop instead of the
  invisible session 0.

  Every invocation is a fresh process, so a whole operation (capture, downscale,
  grid overlay, input injection) happens in one call to keep latency down.

  A single JSON object always goes to stdout, including on failure, so the
  caller never has to parse PowerShell formatting. Coordinates are physical
  pixels of the virtual desktop, which is the space SetCursorPos uses.
#>
param(
  [Parameter(Mandatory = $true)][string]$Command,
  [string]$ParamsB64 = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Write-Json($object) {
  [Console]::Out.Write(($object | ConvertTo-Json -Compress -Depth 8))
}

# Arguments arrive base64-encoded because the caller passes JSON (full of quotes,
# and possibly carrying CJK text) across a Windows command line.
$Params = if ($ParamsB64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ParamsB64)) } else { '{}' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$nativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CuNative
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, int dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}

public static class CuSend
{
    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // Explicit layout so both members share offset 0, exactly like the C union.
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public INPUTUNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    static INPUT Keyboard(ushort vk, ushort scan, uint flags)
    {
        INPUT item = new INPUT();
        item.type = INPUT_KEYBOARD;
        item.u.ki.wVk = vk;
        item.u.ki.wScan = scan;
        item.u.ki.dwFlags = flags;
        return item;
    }

    // KEYEVENTF_UNICODE carries the character in wScan with a zero wVk, which is
    // the only way to type anything outside the CP1252 range (CJK, emoji).
    public static void Unicode(string text)
    {
        foreach (char c in text)
        {
            INPUT[] batch = new INPUT[]
            {
                Keyboard(0, (ushort)c, KEYEVENTF_UNICODE),
                Keyboard(0, (ushort)c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)
            };
            SendInput(2, batch, Marshal.SizeOf(typeof(INPUT)));
        }
    }

    public static void KeyEvent(uint vk, bool up)
    {
        INPUT[] batch = new INPUT[1];
        batch[0] = Keyboard((ushort)vk, 0, up ? KEYEVENTF_KEYUP : 0);
        SendInput(1, batch, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

# Compiling the P/Invoke wrapper costs 1-2s, which would dominate every call.
# Cache the assembly under a content hash so a changed script recompiles and an
# unchanged one just loads (the hash is in the file name to avoid stale reads).
$cacheDir = Join-Path $env:TEMP 'clacky-computer'
$hashBytes = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($nativeSource))
$hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12)
$assemblyPath = Join-Path $cacheDir "CuNative-$hash.dll"

$nativeLoaded = $false
if (Test-Path $assemblyPath) {
  try {
    Add-Type -Path $assemblyPath
    $nativeLoaded = $true
  }
  catch { $nativeLoaded = $false }
}
if (-not $nativeLoaded) {
  if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
  try {
    Add-Type -TypeDefinition $nativeSource -OutputAssembly $assemblyPath -ErrorAction Stop
    Add-Type -Path $assemblyPath
  }
  catch {
    Add-Type -TypeDefinition $nativeSource
  }
}

# Before anything reads screen metrics: a scaled display otherwise reports its
# logical size and every coordinate drifts by the scale factor.
[void][CuNative]::SetProcessDPIAware()

$script:P = $Params | ConvertFrom-Json

$MOUSE = @{
  left   = @{ down = 0x0002; up = 0x0004 }
  right  = @{ down = 0x0008; up = 0x0010 }
  middle = @{ down = 0x0020; up = 0x0040 }
}
$WHEEL = 0x0800
$HWHEEL = 0x1000

function Get-DesktopScreens {
  $index = 0
  @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
    $item = [ordered]@{
      id      = $index
      primary = [bool]$_.Primary
      name    = $_.DeviceName
      x       = $_.Bounds.X
      y       = $_.Bounds.Y
      width   = $_.Bounds.Width
      height  = $_.Bounds.Height
    }
    $index++
    $item
  })
}

function Invoke-Capture {
  if ($null -ne $P.x) {
    $left = [int]$P.x; $top = [int]$P.y
    $width = [int]$P.width; $height = [int]$P.height
  }
  else {
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = $virtual.X; $top = $virtual.Y
    $width = $virtual.Width; $height = $virtual.Height
  }

  $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
  $graphics.Dispose()
  $bitmap.Save($P.path, [System.Drawing.Imaging.ImageFormat]::Png)

  $modelPath = $P.path
  $modelWidth = $bitmap.Width
  $modelHeight = $bitmap.Height
  $maxWidth = if ($null -eq $P.max_width) { 0 } else { [int]$P.max_width }

  if ($maxWidth -gt 0 -and $bitmap.Width -gt $maxWidth) {
    $ratio = $maxWidth / $bitmap.Width
    $resizedWidth = $maxWidth
    $resizedHeight = [Math]::Max([Math]::Round($bitmap.Height * $ratio), 1)
    $resized = New-Object System.Drawing.Bitmap($resizedWidth, $resizedHeight)
    $resizeGraphics = [System.Drawing.Graphics]::FromImage($resized)
    $resizeGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $resizeGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $resizeGraphics.DrawImage($bitmap, 0, 0, $resizedWidth, $resizedHeight)
    $resizeGraphics.Dispose()
    $modelPath = [IO.Path]::ChangeExtension($P.path, $null).TrimEnd('.') + "-$maxWidth.png"
    $resized.Save($modelPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $modelWidth = $resizedWidth
    $modelHeight = $resizedHeight
    $resized.Dispose()
  }
  $bitmap.Dispose()

  $gridStep = if ($null -eq $P.grid_step) { 0 } else { [int]$P.grid_step }
  if ($gridStep -ge 25) {
    $gridPath = [IO.Path]::ChangeExtension($modelPath, $null).TrimEnd('.') + "-grid.png"
    $source = [System.Drawing.Image]::FromFile($modelPath)
    $canvas = New-Object System.Drawing.Bitmap($source.Width, $source.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $canvasGraphics = [System.Drawing.Graphics]::FromImage($canvas)
    $canvasGraphics.DrawImage($source, 0, 0, $source.Width, $source.Height)
    $source.Dispose()

    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(217, 255, 0, 255), 1)
    $font = New-Object System.Drawing.Font('Arial', 12)
    $labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $labelOutline = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)

    for ($x = $gridStep; $x -lt $canvas.Width; $x += $gridStep) {
      $canvasGraphics.DrawLine($pen, $x, 0, $x, $canvas.Height)
      # Outline pass first: labels stay readable over both light and dark pixels.
      $canvasGraphics.DrawString("$x", $font, $labelOutline, ($x + 3), 1)
      $canvasGraphics.DrawString("$x", $font, $labelBrush, ($x + 2), 0)
    }
    for ($y = $gridStep; $y -lt $canvas.Height; $y += $gridStep) {
      $canvasGraphics.DrawLine($pen, 0, $y, $canvas.Width, $y)
      $canvasGraphics.DrawString("$y", $font, $labelOutline, 3, ($y + 1))
      $canvasGraphics.DrawString("$y", $font, $labelBrush, 2, $y)
    }

    $canvasGraphics.Dispose()
    $canvas.Save($gridPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $canvas.Dispose()
    $pen.Dispose(); $font.Dispose(); $labelBrush.Dispose(); $labelOutline.Dispose()
    $modelPath = $gridPath
  }

  Write-Json ([ordered]@{
    ok            = $true
    path          = $P.path
    model_path    = $modelPath
    image_width   = $modelWidth
    image_height  = $modelHeight
    origin_x      = $left
    origin_y      = $top
    points_width  = $width
    points_height = $height
  })
}

function Invoke-Move {
  [void][CuNative]::SetCursorPos([int]$P.x, [int]$P.y)
}

function Invoke-Click {
  $spec = $MOUSE[$P.button]
  $modifiers = @($P.modifiers)
  [void][CuNative]::SetCursorPos([int]$P.x, [int]$P.y)
  Start-Sleep -Milliseconds 30
  $count = if ($null -eq $P.count) { 1 } else { [int]$P.count }
  foreach ($modifier in $modifiers) { [CuSend]::KeyEvent([uint32]$modifier, $false) }
  for ($i = 0; $i -lt $count; $i++) {
    [CuNative]::mouse_event($spec.down, 0, 0, 0, [UIntPtr]::Zero)
    [CuNative]::mouse_event($spec.up, 0, 0, 0, [UIntPtr]::Zero)
    if ($i -lt $count - 1) { Start-Sleep -Milliseconds 60 }
  }
  [array]::Reverse($modifiers)
  foreach ($modifier in $modifiers) { [CuSend]::KeyEvent([uint32]$modifier, $true) }
}

function Invoke-Drag {
  $spec = if ($P.button -and $MOUSE[$P.button]) { $MOUSE[$P.button] } else { $MOUSE['left'] }
  $fromX = [int]$P.from_x; $fromY = [int]$P.from_y
  $toX = [int]$P.to_x; $toY = [int]$P.to_y
  [void][CuNative]::SetCursorPos($fromX, $fromY)
  Start-Sleep -Milliseconds 60
  [CuNative]::mouse_event($spec.down, 0, 0, 0, [UIntPtr]::Zero)
  $steps = 12
  for ($i = 1; $i -le $steps; $i++) {
    $t = $i / $steps
    $stepX = [int]($fromX + ($toX - $fromX) * $t)
    $stepY = [int]($fromY + ($toY - $fromY) * $t)
    [void][CuNative]::SetCursorPos($stepX, $stepY)
    Start-Sleep -Milliseconds 15
  }
  [void][CuNative]::SetCursorPos($toX, $toY)
  Start-Sleep -Milliseconds 40
  [CuNative]::mouse_event($spec.up, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-Scroll {
  [void][CuNative]::SetCursorPos([int]$P.x, [int]$P.y)
  Start-Sleep -Milliseconds 30
  # One wheel notch is 120 units; the caller speaks in pixels, so convert.
  $vertical = [int][Math]::Round([double]$P.dy / 100.0 * 120)
  $horizontal = [int][Math]::Round([double]$P.dx / 100.0 * 120)
  if ($vertical -ne 0) { [CuNative]::mouse_event($WHEEL, 0, 0, $vertical, [UIntPtr]::Zero) }
  if ($horizontal -ne 0) { [CuNative]::mouse_event($HWHEEL, 0, 0, $horizontal, [UIntPtr]::Zero) }
}

function Invoke-Type {
  [CuSend]::Unicode([string]$P.text)
}

function Invoke-Key {
  $modifiers = @($P.modifiers)
  $vk = [uint32]$P.vk
  $repeat = if ($null -eq $P.repeat) { 1 } else { [int]$P.repeat }
  for ($i = 0; $i -lt $repeat; $i++) {
    foreach ($modifier in $modifiers) { [CuSend]::KeyEvent([uint32]$modifier, $false) }
    [CuSend]::KeyEvent($vk, $false)
    [CuSend]::KeyEvent($vk, $true)
    [array]::Reverse($modifiers)
    foreach ($modifier in $modifiers) { [CuSend]::KeyEvent([uint32]$modifier, $true) }
    [array]::Reverse($modifiers)
    Start-Sleep -Milliseconds 50
  }
}

function Invoke-Hold {
  $modifiers = @($P.modifiers)
  foreach ($modifier in $modifiers) { [CuSend]::KeyEvent([uint32]$modifier, $false) }
  Start-Sleep -Milliseconds ([int]([double]$P.duration * 1000))
  [array]::Reverse($modifiers)
  foreach ($modifier in $modifiers) { [CuSend]::KeyEvent([uint32]$modifier, $true) }
}

function Get-ForegroundTitle {
  $handle = [CuNative]::GetForegroundWindow()
  $buffer = New-Object System.Text.StringBuilder 512
  [void][CuNative]::GetWindowText($handle, $buffer, 512)
  $buffer.ToString()
}

function Invoke-Activate {
  $title = [string]$P.app
  $process = Get-Process |
    Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$title*" } |
    Select-Object -First 1

  $opened = $false
  if ($process) {
    [void][CuNative]::ShowWindow($process.MainWindowHandle, 9)   # SW_RESTORE
    $opened = [CuNative]::SetForegroundWindow($process.MainWindowHandle)
  }
  if (-not $opened) {
    # SetForegroundWindow is refused when the caller does not own the foreground;
    # AppActivate goes through the shell and usually still succeeds.
    try {
      $shell = New-Object -ComObject WScript.Shell
      $opened = $shell.AppActivate($title)
    }
    catch { $opened = $false }
  }
  if (-not $opened -and -not $process) {
    $exePath = Join-Path $env:SystemRoot "System32\$title.exe"
    if (Test-Path $exePath) {
      Start-Process $exePath | Out-Null
      Start-Sleep -Milliseconds ([int]([double]$P.wait * 1000))
      $opened = $true
    }
  }

  Write-Json ([ordered]@{
    ok     = $true
    opened = [bool]$opened
    front  = (Get-ForegroundTitle)
  })
}

function Invoke-Info {
  Write-Json ([ordered]@{
    ok         = $true
    session_id = (Get-Process -Id $PID).SessionId
    user       = $env:USERNAME
    computer   = $env:COMPUTERNAME
    screens    = (Get-DesktopScreens)
    virtual    = [ordered]@{
      x      = [System.Windows.Forms.SystemInformation]::VirtualScreen.X
      y      = [System.Windows.Forms.SystemInformation]::VirtualScreen.Y
      width  = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
      height = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height
    }
    cursor     = [ordered]@{
      x = [System.Windows.Forms.Cursor]::Position.X
      y = [System.Windows.Forms.Cursor]::Position.Y
    }
    foreground = (Get-ForegroundTitle)
  })
}

try {
  switch ($Command) {
    'info' { Invoke-Info }
    'capture' { Invoke-Capture }
    'move' { Invoke-Move; Write-Json ([ordered]@{ ok = $true }) }
    'click' { Invoke-Click; Write-Json ([ordered]@{ ok = $true }) }
    'drag' { Invoke-Drag; Write-Json ([ordered]@{ ok = $true }) }
    'scroll' { Invoke-Scroll; Write-Json ([ordered]@{ ok = $true }) }
    'type' { Invoke-Type; Write-Json ([ordered]@{ ok = $true }) }
    'key' { Invoke-Key; Write-Json ([ordered]@{ ok = $true }) }
    'hold' { Invoke-Hold; Write-Json ([ordered]@{ ok = $true }) }
    'activate' { Invoke-Activate }
    default {
      Write-Json ([ordered]@{ ok = $false; error = "unknown command '$Command'" })
      exit 1
    }
  }
}
catch {
  Write-Json ([ordered]@{ ok = $false; error = $_.Exception.Message })
  exit 1
}
