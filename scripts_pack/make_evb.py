# -*- coding: utf-8 -*-
"""Generate an Enigma Virtual Box .evb project file for the MuZhao Windows Release
directory, so `enigmavbconsole.exe muzhao.evb` can pack everything into one exe.

Format reverse-engineered from a real .evb file saved by Enigma Virtual Box GUI
(folder entries: Type=3, file entries: Type=2, root element is literally `<>`).

Usage:
    python make_evb.py <release_dir> <input_exe_name> <output_boxed_exe> <evb_path>

Paths are written in windows-1252 encoding as Enigma does (our paths are ASCII).
"""
import os
import sys

FILE_TMPL = """      <File>
        <Type>2</Type>
        <Name>{name}</Name>
        <File>{full}</File>
        <ActiveX>False</ActiveX>
        <ActiveXInstall>False</ActiveXInstall>
        <Action>0</Action>
        <OverwriteDateTime>False</OverwriteDateTime>
        <OverwriteAttributes>False</OverwriteAttributes>
        <PassCommandLine>False</PassCommandLine>
        <HideFromDialogs>0</HideFromDialogs>
      </File>"""

REGISTRIES = """  <Registries>
    <Enabled>False</Enabled>
    <Registries>
      <Registry>
        <Type>1</Type>
        <Virtual>True</Virtual>
        <Name>Classes</Name>
        <ValueType>0</ValueType>
        <Value/>
        <Registries/>
      </Registry>
      <Registry>
        <Type>1</Type>
        <Virtual>True</Virtual>
        <Name>User</Name>
        <ValueType>0</ValueType>
        <Value/>
        <Registries/>
      </Registry>
      <Registry>
        <Type>1</Type>
        <Virtual>True</Virtual>
        <Name>Machine</Name>
        <ValueType>0</ValueType>
        <Value/>
        <Registries/>
      </Registry>
      <Registry>
        <Type>1</Type>
        <Virtual>True</Virtual>
        <Name>Users</Name>
        <ValueType>0</ValueType>
        <Value/>
        <Registries/>
      </Registry>
      <Registry>
        <Type>1</Type>
        <Virtual>True</Virtual>
        <Name>Config</Name>
        <ValueType>0</ValueType>
        <Value/>
        <Registries/>
      </Registry>
    </Registries>
  </Registries>"""


def xml_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def emit_dir(dir_path, rel_prefix, indent):
    """Emit <File> entries for contents of dir_path. rel_prefix is the virtual
    folder name relative to %DEFAULT FOLDER% ('' means root)."""
    pad = " " * indent
    entries = sorted(os.listdir(dir_path))
    out = []
    for name in entries:
        full = os.path.join(dir_path, name)
        vname = xml_escape(name)
        if os.path.isdir(full):
            out.append(f"{pad}<File>\n{pad}  <Type>3</Type>\n{pad}  <Name>{vname}</Name>\n"
                       f"{pad}  <Action>0</Action>\n{pad}  <OverwriteDateTime>False</OverwriteDateTime>\n"
                       f"{pad}  <OverwriteAttributes>False</OverwriteAttributes>\n"
                       f"{pad}  <HideFromDialogs>0</HideFromDialogs>\n{pad}  <Files>\n")
            out.append(emit_dir(full, rel_prefix + [name], indent + 4))
            out.append(f"{pad}  </Files>\n{pad}</File>\n")
        else:
            vf = xml_escape(os.path.abspath(full))
            out.append(f"{pad}<File>\n{pad}  <Type>2</Type>\n{pad}  <Name>{vname}</Name>\n"
                       f"{pad}  <File>{vf}</File>\n{pad}  <ActiveX>False</ActiveX>\n"
                       f"{pad}  <ActiveXInstall>False</ActiveXInstall>\n{pad}  <Action>0</Action>\n"
                       f"{pad}  <OverwriteDateTime>False</OverwriteDateTime>\n"
                       f"{pad}  <OverwriteAttributes>False</OverwriteAttributes>\n"
                       f"{pad}  <PassCommandLine>False</PassCommandLine>\n"
                       f"{pad}  <HideFromDialogs>0</HideFromDialogs>\n{pad}</File>\n")
    return "".join(out)


def main():
    release_dir = os.path.abspath(sys.argv[1])
    input_exe = sys.argv[2]  # e.g. muzhao.exe
    output_exe = os.path.abspath(sys.argv[3])
    evb_path = sys.argv[4]

    parts = []
    parts.append('<?xml version="1.0" encoding="windows-1252"?>\n<>\n')
    parts.append(f"  <InputFile>{xml_escape(os.path.join(release_dir, input_exe))}</InputFile>\n")
    parts.append(f"  <OutputFile>{xml_escape(output_exe)}</OutputFile>\n")
    parts.append("  <Files>\n    <Enabled>True</Enabled>\n"
                 "    <DeleteExtractedOnExit>False</DeleteExtractedOnExit>\n"
                 "    <CompressFiles>True</CompressFiles>\n    <Files>\n")
    # The GUI wraps the whole tree in a Type=3 folder node named "%DEFAULT FOLDER%".
    parts.append("      <File>\n        <Type>3</Type>\n        <Name>%DEFAULT FOLDER%</Name>\n"
                 "        <Action>0</Action>\n"
                 "        <OverwriteDateTime>False</OverwriteDateTime>\n"
                 "        <OverwriteAttributes>False</OverwriteAttributes>\n"
                 "        <HideFromDialogs>0</HideFromDialogs>\n        <Files>\n")
    parts.append(emit_dir(release_dir, [], 10))
    parts.append("        </Files>\n      </File>\n")
    parts.append("    </Files>\n  </Files>\n")
    parts.append(REGISTRIES + "\n")
    parts.append("  <Packaging>\n    <Enabled>False</Enabled>\n  </Packaging>\n")
    # v11.30 GUI saves exactly these three Option nodes.
    parts.append("  <Options>\n    <ShareVirtualSystem>False</ShareVirtualSystem>\n"
                 "    <MapExecutableWithTemporaryFile>True</MapExecutableWithTemporaryFile>\n"
                 "    <AllowRunningOfVirtualExeFiles>True</AllowRunningOfVirtualExeFiles>\n"
                 "  </Options>\n")
    parts.append("  <Storage>\n    <Files>\n      <Enabled>False</Enabled>\n"
                 "      <Folder>%DEFAULT FOLDER%\\</Folder>\n"
                 "      <RandomFileNames>False</RandomFileNames>\n"
                 "      <EncryptContent>False</EncryptContent>\n    </Files>\n  </Storage>\n")
    parts.append("</>\n")

    with open(evb_path, "wb") as f:
        f.write(b"\xef\xbb\xbf")  # BOM, as the Enigma GUI writes
        f.write("".join(parts).encode("windows-1252"))
    print(f"wrote {evb_path}")


if __name__ == "__main__":
    main()
