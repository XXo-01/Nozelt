const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const projectRoot = path.resolve(__dirname, '..');
const sourceDir = path.resolve(projectRoot, '..', '..', 'Nozelt-assets');
const outputDir = path.join(projectRoot, 'windows', 'runner', 'resources');
const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];

function monochromeLogoSvg(color) {
  const source = fs.readFileSync(
    path.join(sourceDir, 'nozelt_new_master_logo.svg'),
    'utf8',
  );
  return source.replace(
    /(<svg\b[^>]*>)/,
    `$1<style>#Shield path{fill:none!important;stroke:${color}!important}` +
      `#UpperLineAndRing path,#LowerLineAndRing path{fill:${color}!important}</style>`,
  );
}

async function renderPng(svg, size, scale) {
  const innerSize = Math.max(1, Math.round(size * scale));
  // Remove the SVG canvas margin before sizing for tiny Windows icon slots.
  const cropped = await sharp(Buffer.from(svg)).trim().png().toBuffer();
  const image = await sharp(cropped)
    .resize(innerSize, innerSize, { fit: 'contain' })
    .png()
    .toBuffer();
  return sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: image, gravity: 'centre' }])
    .png()
    .toBuffer();
}

function makeIco(images) {
  const directorySize = 6 + images.length * 16;
  const totalSize =
    directorySize + images.reduce((sum, image) => sum + image.length, 0);
  const ico = Buffer.alloc(totalSize);
  ico.writeUInt16LE(0, 0);
  ico.writeUInt16LE(1, 2);
  ico.writeUInt16LE(images.length, 4);

  let offset = directorySize;
  images.forEach((image, index) => {
    const size = sizes[index];
    const entry = 6 + index * 16;
    ico.writeUInt8(size === 256 ? 0 : size, entry);
    ico.writeUInt8(size === 256 ? 0 : size, entry + 1);
    ico.writeUInt8(0, entry + 2);
    ico.writeUInt8(0, entry + 3);
    ico.writeUInt16LE(1, entry + 4);
    ico.writeUInt16LE(32, entry + 6);
    ico.writeUInt32LE(image.length, entry + 8);
    ico.writeUInt32LE(offset, entry + 12);
    image.copy(ico, offset);
    offset += image.length;
  });
  return ico;
}

async function writeIcon(name, svg, scale = 0.96) {
  const images = [];
  for (const size of sizes) {
    images.push(await renderPng(svg, size, scale));
  }
  fs.mkdirSync(outputDir, { recursive: true });
  fs.writeFileSync(path.join(outputDir, name), makeIco(images));
}

async function main() {
  const appLogo = fs.readFileSync(
    path.join(sourceDir, 'nozelt_new_logo.svg'),
    'utf8',
  );
  await writeIcon('app_icon.ico', appLogo, 0.98);
  await writeIcon('tray_connected.ico', appLogo, 0.96);
  const cropped = await sharp(Buffer.from(appLogo)).trim().png().toBuffer();
  // Retain a transparent safety margin around the outer contour. Flutter must
  // display this asset without a rounded clip or a cover crop.
  await sharp(cropped).resize(496, 496, {fit: 'contain', background: '#00000000'})
    .extend({top: 8, bottom: 8, left: 8, right: 8, background: '#00000000'})
    .png().toFile(path.join(projectRoot, 'assets/branding/nozelt_desktop_logo.png'));
  await writeIcon(
    'tray_disconnected_white.ico',
    monochromeLogoSvg('#ffffff'),
    0.96,
  );
  await writeIcon(
    'tray_disconnected_black.ico',
    monochromeLogoSvg('#111318'),
    0.96,
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
