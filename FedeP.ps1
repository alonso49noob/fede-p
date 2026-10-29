# fede p dice: hola
# Muestra una notificacion estilo Windows Live Messenger varias veces,
# en momentos aleatorios. Todo se configura en config.json (o con -Configurar).
param(
    [switch]$Configurar, # abre la ventana de configuracion
    [switch]$Prueba,     # la muestra una vez, ya mismo
    [switch]$Detener,    # cierra las copias que esten corriendo
    [string]$Config = (Join-Path $PSScriptRoot 'config.json')
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
public class ToastForm : System.Windows.Forms.Form {
    public ToastForm() { DoubleBuffered = true; }
    // no robar el foco: aparece encima sin interrumpir lo que estes haciendo
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x80 | 0x8; // NOACTIVATE | TOOLWINDOW | TOPMOST
            return cp;
        }
    }
}
'@

$Estados = [ordered]@{
    'Conectado'    = @([System.Drawing.Color]::FromArgb(176, 236, 112), [System.Drawing.Color]::FromArgb(84, 178, 32),  [System.Drawing.Color]::FromArgb(52, 128, 18))
    'Ocupado'      = @([System.Drawing.Color]::FromArgb(250, 150, 140), [System.Drawing.Color]::FromArgb(206, 46, 34),  [System.Drawing.Color]::FromArgb(140, 24, 16))
    'Ausente'      = @([System.Drawing.Color]::FromArgb(255, 222, 120), [System.Drawing.Color]::FromArgb(236, 160, 20), [System.Drawing.Color]::FromArgb(170, 104, 8))
    'Desconectado' = @([System.Drawing.Color]::FromArgb(222, 226, 232), [System.Drawing.Color]::FromArgb(150, 158, 170), [System.Drawing.Color]::FromArgb(110, 116, 128))
}

function Get-Config([string]$path) {
    $cfg = [ordered]@{
        Nombre = 'fede p'; Mensaje = 'hola'; Estado = 'Conectado'; Foto = ''
        Veces = 2; Minutos = 15; Segundos = 6; Sonido = $true; Repetir = $true
    }
    if (Test-Path $path) {
        try {
            $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) { if ($null -ne $json.$k) { $cfg[$k] = $json.$k } }
        } catch {}
    }
    return $cfg
}

function Save-Config($cfg, [string]$path) {
    [IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

# Sonidito de dos notas, generado en memoria como WAV
function New-Chime {
    $rate = 44100
    $notes = @(@{ f = 1318.5; d = 0.11 }, @{ f = 1975.5; d = 0.32 })
    $samples = New-Object System.Collections.Generic.List[int16]
    foreach ($n in $notes) {
        $count = [int]($rate * $n.d)
        for ($i = 0; $i -lt $count; $i++) {
            $t = $i / $rate
            $env = [math]::Exp(-$t * 9) * [math]::Min(1, $i / 200)
            $v = [math]::Sin(2 * [math]::PI * $n.f * $t) * 0.6 + [math]::Sin(4 * [math]::PI * $n.f * $t) * 0.15
            $samples.Add([int16]($v * $env * 9000))
        }
    }
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $dataLen = $samples.Count * 2
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $dataLen))
    $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16)
    $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2))
    $w.Write([int16]2); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$dataLen)
    foreach ($s in $samples) { $w.Write($s) }
    $w.Flush(); $ms.Position = 0
    return $ms
}

$script:fotos = @{}
function Get-Foto([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return $null }
    if (-not $script:fotos.ContainsKey($path)) {
        try { $script:fotos[$path] = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($path)))) }
        catch { $script:fotos[$path] = $null }
    }
    return $script:fotos[$path]
}

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90); $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-Glossy($path, [float]$cx, [float]$cy, $centro, $borde) {
    $b = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $b.CenterPoint = New-Object System.Drawing.PointF($cx, $cy)
    $b.CenterColor = $centro
    $b.SurroundColors = @($borde)
    return $b
}

# Foto de perfil: marco del color del estado + foto propia o el muñequito por defecto de Messenger
function Draw-Avatar($g, [float]$x, [float]$y, [float]$s, $cfg) {
    $D = [System.Drawing.Color]
    $col = $Estados[[string]$cfg.Estado]; if (-not $col) { $col = $Estados['Conectado'] }

    # marco: degradado, brillo arriba y filo oscuro
    $frame = New-RoundRect $x $y $s $s ($s * 0.13)
    $g.FillPath((New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.RectangleF($x, $y, $s, $s)), $col[0], $col[1], 60)), $frame)
    $gloss = New-RoundRect ($x + 1) ($y + 1) ($s - 2) ($s * 0.5) ($s * 0.12)
    $g.FillPath((New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.RectangleF($x, $y, $s, ($s * 0.5 + 1))), $D::FromArgb(130, 255, 255, 255), $D::FromArgb(0, 255, 255, 255), 90)), $gloss)
    $g.DrawPath((New-Object System.Drawing.Pen($col[2], 1)), $frame)

    # hueco de la foto
    $in = [math]::Round($s * 0.085)
    $px = $x + $in; $py = $y + $in; $ps = $s - 2 * $in
    $hole = New-RoundRect $px $py $ps $ps ($s * 0.04)
    $prev = $g.Clip
    $g.SetClip($hole)

    # foto elegida; si no hay, avatar.png junto al script; si tampoco, el muñequito dibujado
    $img = Get-Foto ([string]$cfg.Foto)
    if (-not $img) { $img = Get-Foto (Join-Path $PSScriptRoot 'avatar.png') }
    if ($img) {
        $m = [math]::Min($img.Width, $img.Height)
        $src = New-Object System.Drawing.Rectangle([int](($img.Width - $m) / 2), [int](($img.Height - $m) / 2), $m, $m)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($img, (New-Object System.Drawing.RectangleF($px, $py, $ps, $ps)), $src, [System.Drawing.GraphicsUnit]::Pixel)
    } else {
        # fondo gris claro, con un reflejo diagonal abajo
        $g.FillRectangle((New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.RectangleF($px, $py, $ps, $ps)), $D::FromArgb(236, 238, 240), $D::FromArgb(212, 216, 220), 90)), $px, $py, $ps, $ps)
        $sheen = New-Object System.Drawing.Drawing2D.GraphicsPath
        $sheen.AddEllipse(($px - $ps * 0.4), ($py + $ps * 0.62), ($ps * 1.8), ($ps * 0.9))
        $g.FillPath((New-Object System.Drawing.SolidBrush($D::FromArgb(70, 255, 255, 255))), $sheen)

        # cuerpo: campana con el cuello angosto y la base ondulada
        $f = { param($a, $b) New-Object System.Drawing.PointF(($px + $ps * $a), ($py + $ps * $b)) }
        $body = New-Object System.Drawing.Drawing2D.GraphicsPath
        $body.AddBezier((& $f 0.41 0.38), (& $f 0.36 0.42), (& $f 0.27 0.48), (& $f 0.26 0.62))
        $body.AddBezier((& $f 0.26 0.62), (& $f 0.25 0.75), (& $f 0.24 0.85), (& $f 0.30 0.875))
        $body.AddBezier((& $f 0.30 0.875), (& $f 0.37 0.895), (& $f 0.44 0.86), (& $f 0.50 0.855))
        $body.AddBezier((& $f 0.50 0.855), (& $f 0.56 0.86), (& $f 0.63 0.895), (& $f 0.70 0.875))
        $body.AddBezier((& $f 0.70 0.875), (& $f 0.76 0.85), (& $f 0.75 0.75), (& $f 0.74 0.62))
        $body.AddBezier((& $f 0.74 0.62), (& $f 0.73 0.48), (& $f 0.64 0.42), (& $f 0.59 0.38))
        $body.AddBezier((& $f 0.59 0.38), (& $f 0.55 0.36), (& $f 0.45 0.36), (& $f 0.41 0.38))
        $body.CloseFigure()
        # sombra suave del muñeco sobre el fondo
        $g.TranslateTransform(($ps * 0.015), ($ps * 0.025))
        $g.FillPath((New-Object System.Drawing.SolidBrush($D::FromArgb(35, 60, 70, 80))), $body)
        $g.ResetTransform()
        $g.FillPath((New-Glossy $body ($px + $ps * 0.44) ($py + $ps * 0.56) $D::FromArgb(240, 241, 243) $D::FromArgb(146, 151, 158)), $body)
        # brillo vertical a la izquierda del cuerpo
        $g.SetClip($body, [System.Drawing.Drawing2D.CombineMode]::Intersect)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($D::FromArgb(110, 255, 255, 255))), ($px + $ps * 0.33), ($py + $ps * 0.47), ($ps * 0.12), ($ps * 0.32))
        $g.SetClip($hole)

        # cabeza
        $head = New-Object System.Drawing.Drawing2D.GraphicsPath
        $head.AddEllipse(($px + $ps * 0.365), ($py + $ps * 0.085), ($ps * 0.27), ($ps * 0.30))
        $g.FillPath((New-Glossy $head ($px + $ps * 0.46) ($py + $ps * 0.17) $D::White $D::FromArgb(150, 155, 163)), $head)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($D::FromArgb(150, 255, 255, 255))), ($px + $ps * 0.41), ($py + $ps * 0.12), ($ps * 0.09), ($ps * 0.07))
    }
    $g.Clip = $prev
    $g.DrawPath((New-Object System.Drawing.Pen($D::FromArgb(90, 0, 0, 0), 1)), $hole)
}

function Draw-Toast($g, [int]$W, [int]$H, $cfg) {
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $D = [System.Drawing.Color]

    # fondo con un degradado muy suave y borde
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(0, 0, $W, $H)), $D::White, $D::FromArgb(236, 243, 250), 90)
    $g.FillRectangle($bg, 0, 0, $W, $H)
    $g.DrawRectangle((New-Object System.Drawing.Pen($D::FromArgb(150, 170, 195))), 0, 0, ($W - 1), ($H - 1))

    # iconito de Messenger (dos muñequitos)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($D::FromArgb(70, 160, 220))), 13, 8, 7, 7)
    $g.FillPie((New-Object System.Drawing.SolidBrush($D::FromArgb(70, 160, 220))), 10, 15, 13, 12, 180, 180)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($D::FromArgb(110, 190, 60))), 19, 10, 7, 7)
    $g.FillPie((New-Object System.Drawing.SolidBrush($D::FromArgb(110, 190, 60))), 16, 17, 13, 12, 180, 180)
    $g.DrawString('Windows Live Messenger', (New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)), (New-Object System.Drawing.SolidBrush($D::FromArgb(60, 70, 85))), 32, 6)

    Draw-Avatar $g 12 32 76 $cfg

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Trimming = 'EllipsisCharacter'
    $font = New-Object System.Drawing.Font('Segoe UI', 13)
    $g.DrawString("$($cfg.Nombre) dice:", $font, (New-Object System.Drawing.SolidBrush($D::FromArgb(30, 30, 30))), (New-Object System.Drawing.RectangleF(98, 40, ($W - 104), 26)), $fmt)
    $g.DrawString([string]$cfg.Mensaje, $font, (New-Object System.Drawing.SolidBrush($D::FromArgb(110, 110, 110))), (New-Object System.Drawing.RectangleF(98, 66, ($W - 104), ($H - 70))), $fmt)
}

function Show-Toast($cfg) {
    $W = 300; $H = 120
    $hold = [math]::Max(1, [int]$cfg.Segundos) * 1000
    $form = New-Object ToastForm
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Size = New-Object System.Drawing.Size($W, $H)
    $form.BackColor = [System.Drawing.Color]::White
    $form.Opacity = 0
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $finalY = $wa.Bottom - $H - 12
    $form.Location = New-Object System.Drawing.Point(($wa.Right - $W - 12), ($finalY + 30))
    $form.Add_Paint({ param($s, $e) Draw-Toast $e.Graphics $W $H $cfg })

    $t0 = [DateTime]::Now
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 15
    $timer.Add_Tick({
        $ms = ([DateTime]::Now - $t0).TotalMilliseconds
        if ($ms -lt 350) {
            $p = $ms / 350
            $form.Opacity = $p
            $form.Top = [int]($finalY + 30 * (1 - $p) * (1 - $p))
        } elseif ($ms -lt 350 + $hold) {
            $form.Opacity = 1; $form.Top = $finalY
        } elseif ($ms -lt 1050 + $hold) {
            $form.Opacity = 1 - ($ms - 350 - $hold) / 700
        } else {
            $timer.Stop(); $form.Close()
        }
    })
    $form.Add_Click({ $form.Close() })
    $form.Add_Shown({
        $timer.Start()
        if ($cfg.Sonido) { try { (New-Object System.Media.SoundPlayer(New-Chime)).Play() } catch {} }
    })

    [System.Windows.Forms.Application]::Run($form)
    $timer.Dispose(); $form.Dispose()
}

function Start-Hidden([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', "`"$PSCommandPath`"") + $extra
    Start-Process powershell -ArgumentList $argList -WindowStyle Hidden
}

# cierra las copias de FedeP que esten esperando para mostrar (no la configuracion ni las pruebas)
function Stop-FedeP {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*FedeP.ps1*' -and
                       $_.CommandLine -notlike '*-Configurar*' -and $_.CommandLine -notlike '*-Prueba*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
}

function Show-Config {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $cfg = Get-Config $Config
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FedeP - Configuración'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.ClientSize = New-Object System.Drawing.Size(466, 520)
    $form.BackColor = [System.Drawing.Color]::White

    $script:fy = 16
    function Add-Row([string]$texto, $ctl, [int]$ancho = 270) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $texto; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point(16, ($script:fy + 3))
        $ctl.Location = New-Object System.Drawing.Point(178, $script:fy)
        $ctl.Width = $ancho
        $form.Controls.AddRange(@($l, $ctl))
        $script:fy += 34
    }
    function New-Num([int]$min, [int]$max, $val) {
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Minimum = $min; $n.Maximum = $max; $n.Value = [math]::Min($max, [math]::Max($min, [int]$val))
        return $n
    }

    $tNombre = New-Object System.Windows.Forms.TextBox; $tNombre.Text = $cfg.Nombre
    Add-Row 'Nombre' $tNombre
    $tMensaje = New-Object System.Windows.Forms.TextBox; $tMensaje.Text = $cfg.Mensaje
    Add-Row 'Mensaje' $tMensaje
    $cEstado = New-Object System.Windows.Forms.ComboBox; $cEstado.DropDownStyle = 'DropDownList'
    $cEstado.Items.AddRange([object[]]@($Estados.Keys)); $cEstado.SelectedItem = [string]$cfg.Estado
    if ($cEstado.SelectedIndex -lt 0) { $cEstado.SelectedIndex = 0 }
    Add-Row 'Estado (color del marco)' $cEstado 140

    $tFoto = New-Object System.Windows.Forms.TextBox; $tFoto.Text = $cfg.Foto; $tFoto.ReadOnly = $true
    Add-Row 'Foto de perfil' $tFoto
    $script:fy -= 6
    $bExaminar = New-Object System.Windows.Forms.Button; $bExaminar.Text = 'Examinar...'
    $bExaminar.Location = New-Object System.Drawing.Point(178, $script:fy); $bExaminar.Width = 100
    $bDefecto = New-Object System.Windows.Forms.Button; $bDefecto.Text = 'Por defecto'
    $bDefecto.Location = New-Object System.Drawing.Point(284, $script:fy); $bDefecto.Width = 100
    $form.Controls.AddRange(@($bExaminar, $bDefecto))
    $script:fy += 40

    $nVeces = New-Num 1 100 $cfg.Veces
    Add-Row 'Cuántas veces' $nVeces 70
    $nMinutos = New-Num 1 1440 $cfg.Minutos
    Add-Row 'Cada cuántos minutos' $nMinutos 70
    $chRepetir = New-Object System.Windows.Forms.CheckBox; $chRepetir.Text = 'Repetir sin parar'; $chRepetir.Checked = [bool]$cfg.Repetir
    Add-Row '' $chRepetir
    $nSegundos = New-Num 1 120 $cfg.Segundos
    Add-Row 'Segundos en pantalla' $nSegundos 70
    $chSonido = New-Object System.Windows.Forms.CheckBox; $chSonido.Text = 'Reproducir sonido'; $chSonido.Checked = [bool]$cfg.Sonido
    Add-Row '' $chSonido

    $lPrev = New-Object System.Windows.Forms.Label
    $lPrev.Text = 'Vista previa'; $lPrev.AutoSize = $true; $lPrev.ForeColor = [System.Drawing.Color]::Gray
    $lPrev.Location = New-Object System.Drawing.Point(16, $script:fy)
    $prev = New-Object System.Windows.Forms.PictureBox
    $prev.Size = New-Object System.Drawing.Size(300, 120)
    $prev.Location = New-Object System.Drawing.Point(83, ($script:fy + 22))
    $form.Controls.AddRange(@($lPrev, $prev))
    # alto de la ventana segun lo que haya arriba, para que los botones nunca queden debajo de la vista previa
    $form.ClientSize = New-Object System.Drawing.Size(466, ($script:fy + 22 + 120 + 64))

    function Read-Form {
        [ordered]@{
            Nombre = $tNombre.Text; Mensaje = $tMensaje.Text; Estado = [string]$cEstado.SelectedItem; Foto = $tFoto.Text
            Veces = [int]$nVeces.Value; Minutos = [int]$nMinutos.Value; Segundos = [int]$nSegundos.Value; Sonido = $chSonido.Checked
            Repetir = $chRepetir.Checked
        }
    }
    $prev.Add_Paint({ param($s, $e) Draw-Toast $e.Graphics 300 120 (Read-Form) })
    $refresh = { $prev.Invalidate() }
    $tNombre.Add_TextChanged($refresh); $tMensaje.Add_TextChanged($refresh)
    $cEstado.Add_SelectedIndexChanged($refresh); $tFoto.Add_TextChanged($refresh)

    $bExaminar.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Imágenes|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
        if ($dlg.ShowDialog($form) -eq 'OK') { $tFoto.Text = $dlg.FileName }
    })
    $bDefecto.Add_Click({ $tFoto.Text = '' })

    $by = $form.ClientSize.Height - 44
    $bProbar = New-Object System.Windows.Forms.Button; $bProbar.Text = 'Probar'
    $bProbar.SetBounds(16, $by, 80, 30)
    $bDetener = New-Object System.Windows.Forms.Button; $bDetener.Text = 'Detener'
    $bDetener.SetBounds(102, $by, 80, 30)
    $bGuardar = New-Object System.Windows.Forms.Button; $bGuardar.Text = 'Guardar'
    $bGuardar.SetBounds(244, $by, 80, 30)
    $bIniciar = New-Object System.Windows.Forms.Button; $bIniciar.Text = 'Guardar e iniciar'
    $bIniciar.SetBounds(330, $by, 120, 30)
    $form.Controls.AddRange(@($bProbar, $bDetener, $bGuardar, $bIniciar))
    $form.AcceptButton = $bIniciar

    $bProbar.Add_Click({
        $tmp = Join-Path $env:TEMP 'fedep-prueba.json'
        Save-Config (Read-Form) $tmp
        Start-Hidden @('-Prueba', '-Config', "`"$tmp`"")
    })
    $bDetener.Add_Click({
        Stop-FedeP
        [void][System.Windows.Forms.MessageBox]::Show($form, 'FedeP se detuvo.', 'FedeP')
    })
    $bGuardar.Add_Click({ Save-Config (Read-Form) $Config; $form.Close() })
    $bIniciar.Add_Click({
        Save-Config (Read-Form) $Config
        Stop-FedeP
        Start-Hidden @('-Config', "`"$Config`"")
        $form.Close()
    })

    [void]$form.ShowDialog()
}

if ($Detener) { Stop-FedeP; return }
if ($Configurar) { Show-Config; return }

$cfg = Get-Config $Config
if ($Prueba) { Show-Toast $cfg; return }

# cada ciclo de $Minutos minutos elige $Veces momentos al azar; si Repetir, vuelve a empezar
$rnd = New-Object System.Random
do {
    $cfg = Get-Config $Config   # asi los cambios guardados se aplican en el proximo ciclo
    $largo = [math]::Max(1, [int]$cfg.Minutos) * 60
    $momentos = 1..([math]::Max(1, [int]$cfg.Veces)) | ForEach-Object { $rnd.Next(0, $largo) } | Sort-Object
    $inicio = [DateTime]::Now
    foreach ($seg in $momentos) {
        $espera = ($inicio.AddSeconds($seg) - [DateTime]::Now).TotalMilliseconds
        if ($espera -gt 0) { Start-Sleep -Milliseconds ([int]$espera) }
        Show-Toast $cfg
    }
    # esperar a que termine el ciclo antes de empezar el siguiente
    $resto = ($inicio.AddSeconds($largo) - [DateTime]::Now).TotalMilliseconds
    if ($cfg.Repetir -and $resto -gt 0) { Start-Sleep -Milliseconds ([int]$resto) }
} while ($cfg.Repetir)
