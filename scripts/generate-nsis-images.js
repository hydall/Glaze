import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const assetsPath = path.resolve(__dirname, '../assets');

function createSolidBmp(filename, width, height, r, g, b) {
  const rowBytes = width * 3;
  const paddingBytes = (4 - (rowBytes % 4)) % 4;
  const paddedRowBytes = rowBytes + paddingBytes;
  const pixelArraySize = paddedRowBytes * height;
  const fileSize = 54 + pixelArraySize;

  const buf = Buffer.alloc(fileSize);

  // BMP Header
  buf.write('BM', 0); // Signature
  buf.writeUInt32LE(fileSize, 2); // File size
  buf.writeUInt32LE(0, 6); // Reserved
  buf.writeUInt32LE(54, 10); // Pixel array offset

  // DIB Header
  buf.writeUInt32LE(40, 14); // Header size
  buf.writeInt32LE(width, 18); // Width
  buf.writeInt32LE(height, 22); // Height
  buf.writeUInt16LE(1, 26); // Color planes
  buf.writeUInt16LE(24, 28); // Bits per pixel
  buf.writeUInt32LE(0, 30); // Compression method (BI_RGB)
  buf.writeUInt32LE(pixelArraySize, 34); // Image size
  buf.writeInt32LE(2835, 38); // Horizontal resolution
  buf.writeInt32LE(2835, 42); // Vertical resolution
  buf.writeUInt32LE(0, 46); // Color palette
  buf.writeUInt32LE(0, 50); // Important colors

  // Pixel Array
  let offset = 54;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      buf.writeUInt8(b, offset++); // Blue
      buf.writeUInt8(g, offset++); // Green
      buf.writeUInt8(r, offset++); // Red
    }
    // Padding
    for (let p = 0; p < paddingBytes; p++) {
      buf.writeUInt8(0, offset++);
    }
  }

  const file = path.join(assetsPath, filename);
  fs.writeFileSync(file, buf);
  console.log(`Created ${file}`);
}

try {
  // A dark gray UI color
  const r = 40, g = 40, b = 40;
  
  createSolidBmp('installerSidebar.bmp', 164, 314, r, g, b);
  createSolidBmp('installerHeader.bmp', 150, 57, r, g, b);
  console.log("Images successfully generated!");
} catch (error) {
  console.error("Error generating images:", error);
}
