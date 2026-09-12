import { readFileSync } from "node:fs";

for (const file of process.argv.slice(2)) {
  const bytes = readFileSync(file);
  const pe = bytes.readUInt32LE(0x3c);
  const coff = pe + 4;
  const optional = coff + 20;

  if (bytes.toString("ascii", pe, pe + 4) !== "PE\0\0") {
    throw new Error(`Not a PE file: ${file}`);
  }

  const sectionCount = bytes.readUInt16LE(coff + 2);
  const optionalSize = bytes.readUInt16LE(coff + 16);
  const dataDirectory = optional + (bytes.readUInt16LE(optional) === 0x20b ? 112 : 96);
  const sections = Array.from({ length: sectionCount }, (_value, index) => {
    const section = optional + optionalSize + index * 40;
    return {
      size: Math.max(bytes.readUInt32LE(section + 8), bytes.readUInt32LE(section + 16)),
      virtualAddress: bytes.readUInt32LE(section + 12),
      raw: bytes.readUInt32LE(section + 20),
    };
  });

  const offset = (rva) => {
    const section = sections.find(
      (candidate) => rva >= candidate.virtualAddress && rva < candidate.virtualAddress + candidate.size,
    );
    if (!section) throw new Error(`Unmapped RVA ${rva} in ${file}`);
    return section.raw + rva - section.virtualAddress;
  };

  const imports = [];
  const importRva = bytes.readUInt32LE(dataDirectory + 8);
  if (importRva) {
    for (let descriptor = offset(importRva); bytes.readUInt32LE(descriptor + 12); descriptor += 20) {
      const name = offset(bytes.readUInt32LE(descriptor + 12));
      imports.push(bytes.toString("ascii", name, bytes.indexOf(0, name)));
    }
  }

  process.stdout.write(`${JSON.stringify({ file, imports })}\n`);
}
