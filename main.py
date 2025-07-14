import sys
import zipfile
import io
import os
import json
from PyQt6.QtWidgets import QApplication, QMainWindow, QScrollArea, QWidget, QVBoxLayout, QLabel, QFileDialog, QStyleOption, QStyle
from PyQt6.QtGui import QPixmap, QPainter, QImage
from PyQt6.QtCore import Qt, QRect, QPoint, QTimer
from PIL import Image

class PageLabel(QLabel):
    def __init__(self, viewer, global_index):
        super().__init__()
        self.viewer = viewer
        self.global_index = global_index
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.pixmap_loaded = False
        self.loaded_width = 0

    def load_pixmap(self):
        current_width = self.viewer.scroll_area.viewport().width() - 20
        if self.pixmap_loaded and self.loaded_width == current_width:
            return
        try:
            file_idx, local_idx = self.viewer.page_to_file_map[self.global_index]
            zip_file = self.viewer.cbzs[file_idx]['zip']
            image_path = self.viewer.cbzs[file_idx]['images'][local_idx]
            with zip_file.open(image_path) as file:
                img_data = file.read()
            pil_image = Image.open(io.BytesIO(img_data))
            orig_width, orig_height = self.viewer.cbzs[file_idx]['page_sizes'][local_idx]
            scale_factor = current_width / orig_width if orig_width > 0 else 1
            height = int(orig_height * scale_factor) if orig_height > 0 else 100
            pil_image = pil_image.resize((current_width, height), Image.Resampling.LANCZOS)
            pil_image = pil_image.convert('RGB')
            data = pil_image.tobytes()
            qimage = QImage(data, current_width, height, 3 * current_width, QImage.Format.Format_RGB888)
            self.setPixmap(QPixmap.fromImage(qimage))
            self.setFixedHeight(height)
            self.pixmap_loaded = True
            self.loaded_width = current_width
        except Exception as e:
            print(f"Error loading image {self.global_index}: {e}")

    def unload_pixmap(self):
        if not self.pixmap_loaded:
            return
        self.setPixmap(QPixmap())
        self.pixmap_loaded = False
        self.loaded_width = 0

class IndicatorLabel(QLabel):
    def __init__(self, parent):
        super().__init__(parent)
        self.setStyleSheet("background-color: rgba(0, 0, 0, 150); color: white; padding: 5px; border-radius: 5px;")
        self.hide()

    def paintEvent(self, event):
        opt = QStyleOption()
        opt.initFrom(self)
        painter = QPainter(self)
        self.style().drawPrimitive(QStyle.PrimitiveElement.PE_Widget, opt, painter, self)
        super().paintEvent(event)

class CBZViewer(QMainWindow):
    def __init__(self, path=None):
        super().__init__()
        self.setWindowTitle("CBZ Viewer")
        self.resize(800, 600)

        self.scroll_area = QScrollArea(self)
        self.scroll_area.setWidgetResizable(True)
        self.container = QWidget()
        self.layout = QVBoxLayout(self.container)
        self.layout.setContentsMargins(0, 0, 0, 0)
        self.layout.setSpacing(0)
        self.scroll_area.setWidget(self.container)
        self.setCentralWidget(self.scroll_area)

        self.indicator = IndicatorLabel(self)
        self.indicator.move(10, self.height() - 50)

        self.cbzs = []
        self.page_to_file_map = []
        self.file_page_starts = []
        self.labels = []
        self.cumulative_heights = [0]
        self.total_pages = 0
        self.total_height = 0
        self.folder_path = None

        self.scroll_area.verticalScrollBar().valueChanged.connect(self.on_scroll)
        self.resizeEvent = self.on_resize

        if path and os.path.isdir(path):
            self.load_folder(path)
        elif path and os.path.isfile(path):
            self.load_single_cbz(path)
        else:
            path, _ = QFileDialog.getOpenFileName(self, "Open CBZ File or Folder", "", "CBZ Files (*.cbz *.zip)")
            if path:
                if os.path.isdir(path):
                    self.load_folder(path)
                else:
                    self.load_single_cbz(path)
            else:
                sys.exit()

        self.restore_state()

    def load_folder(self, folder_path):
        self.folder_path = folder_path
        cbz_files = sorted([os.path.join(folder_path, f) for f in os.listdir(folder_path) if f.lower().endswith(('.cbz', '.zip'))])
        global_page_idx = 0
        self.file_page_starts = [0]
        self.page_to_file_map = []
        for file_path in cbz_files:
            try:
                zip_file = zipfile.ZipFile(file_path)
            except:
                continue
            images = sorted([f for f in zip_file.namelist() if f.lower().endswith(('.png', '.jpg', '.jpeg'))])
            if not images:
                zip_file.close()
                continue
            page_sizes = []
            for img_path in images:
                try:
                    with zip_file.open(img_path) as file:
                        img_data = file.read()
                    pil_image = Image.open(io.BytesIO(img_data))
                    page_sizes.append((pil_image.width, pil_image.height))
                except:
                    page_sizes.append((0, 0))  # fallback
            self.cbzs.append({'zip': zip_file, 'images': images, 'page_sizes': page_sizes, 'file_name': os.path.basename(file_path)})
            file_idx = len(self.cbzs) - 1
            for local_idx in range(len(images)):
                self.page_to_file_map.append((file_idx, local_idx))
                global_page_idx += 1
            self.file_page_starts.append(global_page_idx)
        self.total_pages = global_page_idx
        if self.total_pages == 0:
            return
        self.labels = [PageLabel(self, i) for i in range(self.total_pages)]
        for lbl in self.labels:
            self.layout.addWidget(lbl)
        self.update_heights()
        self.on_scroll()

    def load_single_cbz(self, path):
        zip_file = zipfile.ZipFile(path)
        images = sorted([f for f in zip_file.namelist() if f.lower().endswith(('.png', '.jpg', '.jpeg'))])
        self.total_pages = len(images)
        if self.total_pages == 0:
            return
        page_sizes = []
        for img_path in images:
            with zip_file.open(img_path) as file:
                img_data = file.read()
            pil_image = Image.open(io.BytesIO(img_data))
            page_sizes.append((pil_image.width, pil_image.height))
        self.cbzs = [{'zip': zip_file, 'images': images, 'page_sizes': page_sizes, 'file_name': os.path.basename(path)}]
        self.page_to_file_map = [(0, i) for i in range(self.total_pages)]
        self.file_page_starts = [0, self.total_pages]
        self.labels = [PageLabel(self, i) for i in range(self.total_pages)]
        for lbl in self.labels:
            self.layout.addWidget(lbl)
        self.update_heights()
        self.on_scroll()

    def update_heights(self):
        width = self.scroll_area.viewport().width() - 20
        cumulative = 0
        self.cumulative_heights = [0]
        for global_idx in range(self.total_pages):
            file_idx, local_idx = self.page_to_file_map[global_idx]
            orig_width, orig_height = self.cbzs[file_idx]['page_sizes'][local_idx]
            scale_factor = width / orig_width if orig_width > 0 else 1
            height = int(orig_height * scale_factor) if orig_height > 0 else 100
            cumulative += height
            self.cumulative_heights.append(cumulative)
            self.labels[global_idx].setFixedHeight(height)
        self.total_height = cumulative if cumulative > 0 else 100
        self.container.setFixedHeight(self.total_height)

    def on_resize(self, event):
        super().resizeEvent(event)
        self.update_heights()
        self.on_scroll()
        self.indicator.move(10, self.height() - 50)

    def on_scroll(self):
        if self.total_pages == 0:
            return

        scroll_pos = self.scroll_area.verticalScrollBar().value()
        visible_height = self.scroll_area.viewport().height()

        try:
            start_page = next(i for i, cum in enumerate(self.cumulative_heights) if cum > scroll_pos) - 1
        except StopIteration:
            start_page = self.total_pages - 1
        try:
            end_page = next(i for i, cum in enumerate(self.cumulative_heights) if cum > scroll_pos + visible_height) - 1
        except StopIteration:
            end_page = self.total_pages - 1

        start_page = max(0, start_page)
        end_page = max(0, end_page)

        load_start = max(0, start_page - 5)
        load_end = min(self.total_pages - 1, end_page + 5)

        for i in range(self.total_pages):
            if load_start <= i <= load_end:
                self.labels[i].load_pixmap()
            else:
                self.labels[i].unload_pixmap()

        current_page = max(1, start_page + 1)
        percentage = int((scroll_pos / self.total_height) * 100) if self.total_height > 0 else 0

        try:
            file_idx = next(i for i, start in enumerate(self.file_page_starts) if start > start_page) - 1
        except StopIteration:
            file_idx = len(self.cbzs) - 1
        file_idx = max(0, min(file_idx, len(self.cbzs) - 1))

        current_file = self.cbzs[file_idx]['file_name'] if file_idx < len(self.cbzs) else ''
        local_page = max(1, (start_page - self.file_page_starts[file_idx]) + 1)
        local_total = len(self.cbzs[file_idx]['images']) if file_idx < len(self.cbzs) else 0

        self.indicator.setText(f"{current_file} - Page {local_page}/{local_total} | Global: {current_page}/{self.total_pages} ({percentage}%)")
        self.indicator.adjustSize()
        self.indicator.show()

    def showEvent(self, event):
        super().showEvent(event)
        self.restore_state()

    def restore_state(self):
        if self.folder_path:
            state_file = os.path.join(self.folder_path, '.cbzviewer_state.json')
            if os.path.exists(state_file):
                try:
                    with open(state_file, 'r') as f:
                        state = json.load(f)
                    scroll_pos = state.get('scroll_pos', 0)
                    print(f"Restoring scroll position: {scroll_pos}")
                    QTimer.singleShot(0, lambda: self.scroll_area.verticalScrollBar().setValue(scroll_pos))
                    QTimer.singleShot(100, self.on_scroll)  # Ensure loading after set
                except Exception as e:
                    print(f"Error restoring state: {e}")

    def closeEvent(self, event):
        if self.folder_path:
            state_file = os.path.join(self.folder_path, '.cbzviewer_state.json')
            scroll_pos = self.scroll_area.verticalScrollBar().value()
            state = {'scroll_pos': scroll_pos}
            print(f"Saving scroll position: {scroll_pos}")
            try:
                with open(state_file, 'w') as f:
                    json.dump(state, f)
            except Exception as e:
                print(f"Error saving state: {e}")
        for cbz in self.cbzs:
            cbz['zip'].close()
        super().closeEvent(event)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    path = sys.argv[1] if len(sys.argv) > 1 else None
    viewer = CBZViewer(path)
    viewer.show()
    sys.exit(app.exec()) 