using System;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace VntBrandRepackager
{
    internal sealed class MainForm : Form
    {
        private readonly TextBox _installerText = new TextBox();
        private readonly TextBox _productNameText = new TextBox();
        private readonly TextBox _iconText = new TextBox();
        private readonly Label _packageStatusLabel = new Label();
        private readonly CheckBox _hideAboutPageCheck = new CheckBox();
        private readonly CheckBox _removeUpdateFeatureCheck = new CheckBox();
        private readonly Button _packButton = new Button();
        private readonly RichTextBox _logText = new RichTextBox();
        private int _inspectionGeneration;

        public MainForm()
        {
            Text = "VNT 一键品牌换牌工具";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(760, 630);
            Size = new Size(820, 700);
            Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Regular);
            BackColor = Color.FromArgb(244, 247, 251);
            AllowDrop = true;
            DragEnter += OnDragEnter;
            DragDrop += OnDragDrop;

            var title = new Label
            {
                Text = "导入 EXE 或 APK，自动识别后重新打包",
                Dock = DockStyle.Top,
                Height = 54,
                Font = new Font("Microsoft YaHei UI", 17F, FontStyle.Bold),
                ForeColor = Color.FromArgb(27, 45, 73),
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(22, 0, 0, 0)
            };
            var hint = new Label
            {
                Text = "默认移除升级功能，避免下级用户误升级；取消后可能恢复官方更新。",
                Dock = DockStyle.Top,
                Height = 34,
                ForeColor = Color.FromArgb(82, 99, 125),
                Padding = new Padding(24, 0, 0, 0)
            };

            var grid = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 299,
                Padding = new Padding(22, 8, 22, 4),
                ColumnCount = 3,
                RowCount = 6,
                BackColor = BackColor
            };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 118));
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
            for (var row = 0; row < 6; row++)
            {
                grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 47));
            }

            AddRow(grid, 0, "源安装包", _installerText, "导入", BrowseInstaller);
            AddStatusRow(grid, 1, "自动识别", _packageStatusLabel);
            AddRow(grid, 2, "输入新名称", _productNameText, null, null);
            AddRow(grid, 3, "添加新图标（可选）", _iconText, "添加", BrowseIcon);
            AddOptionRow(
                grid,
                4,
                "升级策略",
                _removeUpdateFeatureCheck,
                "移除升级功能（推荐，默认勾选）",
                true);
            AddOptionRow(
                grid,
                5,
                "页面选项",
                _hideAboutPageCheck,
                "隐藏“关于”页面（仅客户分发版）",
                false);
            _installerText.TextChanged += InstallerTextChanged;

            _packButton.Text = "重新打包";
            _packButton.Dock = DockStyle.Top;
            _packButton.Height = 48;
            _packButton.Margin = new Padding(22, 8, 22, 8);
            _packButton.FlatStyle = FlatStyle.Flat;
            _packButton.FlatAppearance.BorderSize = 0;
            _packButton.BackColor = Color.FromArgb(38, 105, 217);
            _packButton.ForeColor = Color.White;
            _packButton.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
            _packButton.Click += PackButtonClick;

            var buttonPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 68,
                Padding = new Padding(22, 8, 22, 8)
            };
            buttonPanel.Controls.Add(_packButton);

            _logText.Dock = DockStyle.Fill;
            _logText.ReadOnly = true;
            _logText.BackColor = Color.FromArgb(28, 34, 43);
            _logText.ForeColor = Color.FromArgb(221, 231, 242);
            _logText.BorderStyle = BorderStyle.None;
            _logText.Font = new Font("Consolas", 9.5F);
            _logText.Margin = new Padding(22);

            var logPanel = new Panel
            {
                Dock = DockStyle.Fill,
                Padding = new Padding(22, 4, 22, 22)
            };
            logPanel.Controls.Add(_logText);

            Controls.Add(logPanel);
            Controls.Add(buttonPanel);
            Controls.Add(grid);
            Controls.Add(hint);
            Controls.Add(title);
        }

        private static void AddRow(
            TableLayoutPanel grid,
            int row,
            string labelText,
            TextBox textBox,
            string buttonText,
            EventHandler click)
        {
            var label = new Label
            {
                Text = labelText,
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Color.FromArgb(45, 60, 82)
            };
            textBox.Dock = DockStyle.Fill;
            textBox.Margin = new Padding(0, 8, 8, 8);
            grid.Controls.Add(label, 0, row);
            grid.Controls.Add(textBox, 1, row);

            if (buttonText != null)
            {
                var button = new Button
                {
                    Text = buttonText,
                    Dock = DockStyle.Fill,
                    Margin = new Padding(0, 6, 0, 6)
                };
                button.Click += click;
                grid.Controls.Add(button, 2, row);
            }
        }

        private static void AddOptionRow(
            TableLayoutPanel grid,
            int row,
            string labelText,
            CheckBox checkBox,
            string optionText,
            bool defaultChecked)
        {
            var label = new Label
            {
                Text = labelText,
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Color.FromArgb(45, 60, 82)
            };
            checkBox.Text = optionText;
            checkBox.Dock = DockStyle.Fill;
            checkBox.Margin = new Padding(0, 8, 0, 8);
            checkBox.Checked = defaultChecked;
            grid.Controls.Add(label, 0, row);
            grid.Controls.Add(checkBox, 1, row);
            grid.SetColumnSpan(checkBox, 2);
        }

        private static void AddStatusRow(
            TableLayoutPanel grid,
            int row,
            string labelText,
            Label statusLabel)
        {
            var label = new Label
            {
                Text = labelText,
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Color.FromArgb(45, 60, 82)
            };
            statusLabel.Text = "等待导入安装包";
            statusLabel.Dock = DockStyle.Fill;
            statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            statusLabel.ForeColor = Color.FromArgb(82, 99, 125);
            grid.Controls.Add(label, 0, row);
            grid.Controls.Add(statusLabel, 1, row);
            grid.SetColumnSpan(statusLabel, 2);
        }

        private void BrowseInstaller(object sender, EventArgs args)
        {
            using (var dialog = new OpenFileDialog
            {
                Filter = "支持的安装包 (*.exe;*.apk)|*.exe;*.apk|" +
                    "Windows 安装包 (*.exe)|*.exe|Android 安装包 (*.apk)|*.apk|" +
                    "所有文件 (*.*)|*.*",
                Title = "选择支持换牌的 EXE 或 APK 母版安装包"
            })
            {
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    _installerText.Text = dialog.FileName;
                }
            }
        }

        private void BrowseIcon(object sender, EventArgs args)
        {
            using (var dialog = new OpenFileDialog
            {
                Filter = "支持的图标图片|*.ico;*.png;*.jpg;*.jpeg;*.bmp|" +
                    "Windows 图标 (*.ico)|*.ico|PNG 图片 (*.png)|*.png|" +
                    "JPEG 图片 (*.jpg;*.jpeg)|*.jpg;*.jpeg|BMP 图片 (*.bmp)|*.bmp",
                Title = "添加新图标（可选，大图自动压缩）"
            })
            {
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    _iconText.Text = dialog.FileName;
                }
            }
        }

        private async void PackButtonClick(object sender, EventArgs args)
        {
            try
            {
                var request = new BrandPackageRequest
                {
                    InstallerPath = _installerText.Text,
                    ProductName = _productNameText.Text,
                    IconPath = _iconText.Text,
                    HideAboutPage = _hideAboutPageCheck.Checked,
                    UpdateEnabled = !_removeUpdateFeatureCheck.Checked
                };
                var inspection = BrandPackager.ValidateInputs(request);
                var isAndroid = inspection.Format == PackageFormat.AndroidApk;
                var safeName = request.ProductName.Trim().Replace(' ', '_');
                var versionPart = string.IsNullOrWhiteSpace(inspection.Version)
                    ? string.Empty
                    : "_" + inspection.Version;
                using (var dialog = new SaveFileDialog
                {
                    AddExtension = true,
                    CheckPathExists = true,
                    DefaultExt = isAndroid ? "apk" : "exe",
                    Filter = isAndroid
                        ? "Android 安装包 (*.apk)|*.apk"
                        : "Windows 安装包 (*.exe)|*.exe",
                    FileName = safeName + versionPart +
                        (isAndroid ? "_Android_arm64.apk" : "_Windows_Setup.exe"),
                    InitialDirectory = Path.GetDirectoryName(request.InstallerPath),
                    OverwritePrompt = true,
                    RestoreDirectory = true,
                    Title = "保存重新打包后的安装包"
                })
                {
                    if (dialog.ShowDialog(this) != DialogResult.OK)
                    {
                        return;
                    }
                    request.OutputInstallerPath = dialog.FileName;
                }

                _packButton.Enabled = false;
                _logText.Clear();
                AppendLog("保存位置：" + request.OutputInstallerPath);
                var packager = new BrandPackager(AppendLog);
                var result = await Task.Run(() => packager.Pack(request));
                AppendLog("完成：" + result.InstallerPath);
                MessageBox.Show(
                    this,
                    "安装包已生成：\n" + result.InstallerPath +
                    "\n\n识别类型：" +
                    (result.Format == PackageFormat.AndroidApk
                        ? "Android APK"
                        : "Windows EXE") +
                    "\n进程标识：" + result.ProcessIdentifier +
                    "\n关于页面：" +
                    (request.HideAboutPage ? "已隐藏" : "保留显示") +
                    "\n升级功能：" +
                    (request.UpdateEnabled
                        ? "保留（请确保使用同品牌更新包）"
                        : "已移除"),
                    "打包完成",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception error)
            {
                AppendLog("失败：" + error.Message);
                MessageBox.Show(
                    this,
                    error.Message,
                    "打包失败",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            finally
            {
                _packButton.Enabled = true;
            }
        }

        private void AppendLog(string message)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), message);
                return;
            }
            _logText.AppendText(
                DateTime.Now.ToString("HH:mm:ss") + "  " + message + Environment.NewLine);
            _logText.ScrollToCaret();
        }

        private void OnDragEnter(object sender, DragEventArgs args)
        {
            args.Effect = args.Data.GetDataPresent(DataFormats.FileDrop)
                ? DragDropEffects.Copy
                : DragDropEffects.None;
        }

        private void OnDragDrop(object sender, DragEventArgs args)
        {
            var files = args.Data.GetData(DataFormats.FileDrop) as string[];
            if (files != null && files.Length > 0 && File.Exists(files[0]))
            {
                _installerText.Text = files[0];
            }
        }

        private async void InstallerTextChanged(object sender, EventArgs args)
        {
            var generation = ++_inspectionGeneration;
            var path = _installerText.Text.Trim();
            if (string.IsNullOrWhiteSpace(path))
            {
                _packageStatusLabel.Text = "等待导入安装包";
                _packageStatusLabel.ForeColor = Color.FromArgb(82, 99, 125);
                return;
            }

            _packageStatusLabel.Text = "正在按文件内容识别…";
            _packageStatusLabel.ForeColor = Color.FromArgb(82, 99, 125);
            var inspection = await Task.Run(() => PackageDetector.Inspect(path));
            if (generation != _inspectionGeneration || IsDisposed)
            {
                return;
            }
            if (inspection.IsSupported)
            {
                _packageStatusLabel.Text = "已识别：" +
                    inspection.PlatformDisplayName +
                    (string.IsNullOrWhiteSpace(inspection.Version)
                        ? string.Empty
                        : " · v" + inspection.Version);
                _packageStatusLabel.ForeColor = Color.FromArgb(24, 128, 78);
            }
            else
            {
                _packageStatusLabel.Text = "不支持：" + inspection.ErrorMessage;
                _packageStatusLabel.ForeColor = Color.FromArgb(187, 50, 50);
            }
        }
    }
}
