# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Rule for building a Container layer."""

load(
    "//skylib:filetype.bzl",
    container_filetype = "container",
    deb_filetype = "deb",
    tar_filetype = "tar",
)
load(
    "@bazel_tools//tools/build_defs/hash:hash.bzl",
    _hash_tools = "tools",
    _sha256 = "sha256",
)
load(
    "//skylib:zip.bzl",
    _gzip = "gzip",
)
load(
    "//container:layer_tools.bzl",
    _assemble_image = "assemble",
    _get_layers = "get_from_target",
    _incr_load = "incremental_load",
    _layer_tools = "tools",
)
load(
    "//skylib:path.bzl",
    "dirname",
    "strip_prefix",
    _canonicalize_path = "canonicalize",
    _join_path = "join",
)

def magic_path(ctx, f):
  # Right now the logic this uses is a bit crazy/buggy, so to support
  # bug-for-bug compatibility in the foo_image rules, expose the logic.
  # See also: https://github.com/bazelbuild/rules_docker/issues/106
  # See also: https://groups.google.com/forum/#!topic/bazel-discuss/1lX3aiTZX3Y

  if ctx.attr.data_path:
    # If data_prefix is specified, then add files relative to that.
    data_path = _join_path(
        dirname(ctx.outputs.layer.short_path),
        _canonicalize_path(ctx.attr.data_path))
    return strip_prefix(f.short_path, data_path)
  else:
    # Otherwise, files are added without a directory prefix at all.
    return f.basename

def _build_layer(ctx, files=None, file_map=None, empty_files=None,
                 directory=None, symlinks=None, debs=None, tars=None):
  """Build the current layer for appending it to the base layer"""
  layer = ctx.outputs.layer
  build_layer = ctx.executable.build_layer
  args = [
      "--output=" + layer.path,
      "--directory=" + directory,
      "--mode=" + ctx.attr.mode,
  ]

  args += ["--file=%s=%s" % (f.path, magic_path(ctx, f)) for f in files]
  args += ["--file=%s=%s" % (f.path, path) for (path, f) in file_map.items()]
  args += ["--empty_file=%s" % f for f in empty_files or []]
  args += ["--tar=" + f.path for f in tars]
  args += ["--deb=" + f.path for f in debs]
  for k in symlinks:
    if ":" in k:
      fail("The source of a symlink cannot container ':', got: %s" % k)
  args += ["--link=%s:%s" % (k, symlinks[k]) for k in symlinks]
  arg_file = ctx.new_file(ctx.label.name + "-layer.args")
  ctx.file_action(arg_file, "\n".join(args))
  ctx.action(
      executable = build_layer,
      arguments = ["--flagfile=" + arg_file.path],
      inputs = files + file_map.values() + tars + debs + [arg_file],
      outputs = [layer],
      use_default_shell_env = True,
      mnemonic="ImageLayer",
  )
  return layer, _sha256(ctx, layer)

def _zip_layer(ctx, layer):
  zipped_layer = _gzip(ctx, layer)
  return zipped_layer, _sha256(ctx, zipped_layer)

LayerInfo = provider()

def _impl(ctx, files=None, file_map=None, empty_files=None, directory=None,
          symlinks=None, output=None, env=None, debs=None, tars=None):
  """Implementation for the container_layer rule.

  Args:
    ctx: The bazel rule context
    files: File list, overrides ctx.files.files
    file_map: Dict[str, File], defaults to {}
    empty_files: str list, overrides ctx.attr.empty_files
    directory: str, overrides ctx.attr.directory
    symlinks: str Dict, overrides ctx.attr.symlinks
    env: str Dict, overrides ctx.attr.env
    debs: File list, overrides ctx.files.debs
    tars: File list, overrides ctx.files.tars
"""
  file_map = file_map or {}
  files = files or ctx.files.files
  empty_files = empty_files or ctx.attr.empty_files
  directory = directory or ctx.attr.directory
  symlinks = symlinks or ctx.attr.symlinks
  env = env or ctx.attr.env
  debs = debs or ctx.files.debs
  tars = tars or ctx.files.tars
  # Generate the unzipped filesystem layer, and its sha256 (aka diff_id)
  unzipped_layer, diff_id = _build_layer(ctx, files=files, file_map=file_map,
                                         empty_files=empty_files,
                                         directory=directory, symlinks=symlinks,
                                         debs=debs, tars=tars)
  # Generate the zipped filesystem layer, and its sha256 (aka blob sum)
  zipped_layer, blob_sum = _zip_layer(ctx, unzipped_layer)
  # Returns constituent parts of the Container layer as provider
  return [LayerInfo(zipped_layer=zipped_layer,
                    blob_sum=blob_sum,
                    unzipped_layer=unzipped_layer,
                    diff_id=diff_id,
                    env=env)]


_layer_attrs = dict({
    "data_path": attr.string(),
    "directory": attr.string(default = "/"),
    "tars": attr.label_list(allow_files = tar_filetype),
    "debs": attr.label_list(allow_files = deb_filetype),
    "files": attr.label_list(allow_files = True),
    "docker_run_flags": attr.string(),
    "mode": attr.string(default = "0555"),  # 0555 == a+rx
    "symlinks": attr.string_dict(),
    "env": attr.string_dict(),
    # Implicit/Undocumented dependencies.
    "empty_files": attr.string_list(),
    "build_layer": attr.label(
        default = Label("//container:build_tar"),
        cfg = "host",
        executable = True,
        allow_files = True,
    ),
}.items() + _hash_tools.items() + _layer_tools.items())

_layer_outputs = {
    "layer": "%{name}-layer.tar"
}

container_layer_ = rule(
    attrs = _layer_attrs,
    executable = False,
    outputs = _layer_outputs,
    implementation = _impl,
)

def container_layer(**kwargs):
  container_layer_(**kwargs)
