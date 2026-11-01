#!/usr/bin/env python3
"""Подключает f2qdsp к исходникам llama.cpp (проверено на тэге v0.8.0).

python3 patch_llama.py <llama.cpp>   - патч идемпотентный: повторный запуск ничего не ломает.
Дальше: cmake -DGGML_CPU_F2QDSP=ON -DGGML_CPU_F2QDSP_SRC=<npu> -DGGML_CPU_F2QDSP_GEN=<вывод qaic>
              -DGGML_CPU_F2QDSP_SDK=<Hexagon SDK> [-DGGML_CPU_F2QDSP_MOCK=ON]
"""
import sys
from pathlib import Path

MARK = "f2qdsp"


def patch(path: Path, anchor: str, text: str, after: bool = True) -> None:
    s = path.read_text()
    if MARK in s and text.strip() in s:
        print(f"{path}: уже пропатчен")
        return
    n = s.count(anchor)
    if n != 1:
        sys.exit(f"{path}: якорь найден {n} раз(а), ожидался 1: {anchor!r} - другая версия llama.cpp?")
    s = s.replace(anchor, anchor + text if after else text + anchor)
    path.write_text(s)
    print(f"{path}: OK")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(sys.argv[1])
    ggml = root / "ggml"

    patch(ggml / "CMakeLists.txt",
          'option(GGML_CPU_KLEIDIAI     "ggml: use KleidiAI optimized kernels if applicable" OFF)\n',
          'option(GGML_CPU_F2QDSP       "ggml: f2qdsp - MUL_MAT on Hexagon cDSP (SM8250, FastRPC)" OFF)\n'
          'option(GGML_CPU_F2QDSP_MOCK  "ggml: f2qdsp - DSP emulated in-process (tests)" OFF)\n'
          'set(GGML_CPU_F2QDSP_SRC "" CACHE PATH "f2qdsp: npu/ directory")\n'
          'set(GGML_CPU_F2QDSP_GEN "" CACHE PATH "f2qdsp: qaic output (f2qdsp.h, f2qdsp_stub.c, f2qdsp_skel.c)")\n'
          'set(GGML_CPU_F2QDSP_SDK "" CACHE PATH "f2qdsp: Hexagon SDK root (incs/)")\n')

    patch(ggml / "src" / "ggml-cpu" / "ggml-cpu.cpp",
          '#include "amx/amx.h"\n',
          '\n#ifdef GGML_USE_CPU_F2QDSP\n#    include "ggml-f2qdsp.h" // f2qdsp\n#endif\n')

    patch(ggml / "src" / "ggml-cpu" / "ggml-cpu.cpp",
          '        std::vector<ggml_backend_buffer_type_t> bufts;\n',
          '\n#ifdef GGML_USE_CPU_F2QDSP\n'
          '        // f2qdsp первым: ему достаются веса Q4_0/Q8_0 в пределах F2QDSP_MAX_MB, остальное - repack/CPU\n'
          '        if (ggml_backend_cpu_f2qdsp_buffer_type()) {\n'
          '            bufts.push_back(ggml_backend_cpu_f2qdsp_buffer_type());\n'
          '        }\n'
          '#endif\n')

    patch(ggml / "src" / "ggml-cpu" / "CMakeLists.txt",
          '    message(STATUS "Adding CPU backend variant ${GGML_CPU_NAME}: ${ARCH_FLAGS} ${ARCH_DEFINITIONS}")\n',
          '''    if (GGML_CPU_F2QDSP) # f2qdsp
        foreach (v GGML_CPU_F2QDSP_SRC GGML_CPU_F2QDSP_GEN GGML_CPU_F2QDSP_SDK)
            if (NOT EXISTS "${${v}}")
                message(FATAL_ERROR "f2qdsp: ${v} не задан или не существует: '${${v}}'")
            endif()
        endforeach()
        set(F2Q ${GGML_CPU_F2QDSP_SRC})
        set(F2Q_SRCS ${F2Q}/ggml/ggml-f2qdsp.cpp ${F2Q}/ap/f2q_dev.c ${F2Q}/ap/f2q_cpu.c
                     ${F2Q}/common/f2q_pack.c ${F2Q}/dsp/f2q_kernel.c)
        set(F2Q_INC "${GGML_CPU_F2QDSP_GEN};${GGML_CPU_F2QDSP_SDK}/incs;${GGML_CPU_F2QDSP_SDK}/incs/stddef")
        set_source_files_properties(${F2Q}/ap/f2q_dev.c PROPERTIES INCLUDE_DIRECTORIES "${F2Q_INC}")
        if (GGML_CPU_F2QDSP_MOCK)
            list(APPEND F2Q_SRCS ${F2Q}/test/mock/mock_dsp.c)
            set_source_files_properties(${F2Q}/test/mock/mock_dsp.c PROPERTIES INCLUDE_DIRECTORIES "${F2Q}/test/mock;${F2Q_INC}")
            set_source_files_properties(${F2Q}/ap/f2q_dev.c ${F2Q}/test/mock/mock_dsp.c PROPERTIES COMPILE_DEFINITIONS F2QDSP_MOCK)
        endif()
        set_source_files_properties(${F2Q_SRCS} PROPERTIES COMPILE_OPTIONS "-ffp-contract=off;-fno-strict-aliasing")
        list(APPEND GGML_CPU_SOURCES ${F2Q_SRCS})
        target_include_directories(${GGML_CPU_NAME} PRIVATE ${F2Q}/ggml)
        target_compile_definitions(${GGML_CPU_NAME} PRIVATE GGML_USE_CPU_F2QDSP)
        target_link_libraries(${GGML_CPU_NAME} PRIVATE ${CMAKE_DL_LIBS})
    endif()

''', after=False)


if __name__ == "__main__":
    main()
