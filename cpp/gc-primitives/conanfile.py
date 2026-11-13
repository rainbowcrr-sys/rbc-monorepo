from conan import ConanFile
from conan.tools.files import copy
import os


class GcPrimitivesConan(ConanFile):
    name = "gc-primitives"
    version = "0.2.0"
    license = "Apache-2.0"
    url = "https://github.com/rainbowcrr-sys/rbc-monorepo"
    description = "Allocation-reducing object pooling primitives for C++17 (header-only)"
    topics = ("object-pool", "allocation", "header-only", "zero-dependency")
    settings = None  # header-only：与平台/编译器/构建类型无关
    no_copy_source = True
    exports_sources = "include/*", "LICENSE"

    def package(self):
        copy(self, "*.hpp", src=os.path.join(self.source_folder, "include"),
             dst=os.path.join(self.package_folder, "include"))
        copy(self, "LICENSE", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses"))

    def package_info(self):
        self.cpp_info.set_property("cmake_target_name", "rbc::gc_primitives")
        self.cpp_info.bindirs = []
        self.cpp_info.libdirs = []
        self.cpp_info.requires = []
        self.cpp_info.components["_gc_primitives"].includedirs = ["include"]
        self.cpp_info.cxxflags = []

    def package_id(self):
        self.info.clear()  # 单一 header-only 包，无二进制变体
