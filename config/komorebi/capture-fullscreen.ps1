$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
  $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
  $screenshotsDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'
  [void][System.IO.Directory]::CreateDirectory($screenshotsDir)
  $outputPath = Join-Path $screenshotsDir ('Screenshot {0}.png' -f (Get-Date -Format 'yyyy-MM-dd HHmmss'))
  $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
} finally {
  $graphics.Dispose()
  $bitmap.Dispose()
}
