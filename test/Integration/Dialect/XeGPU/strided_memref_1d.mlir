// RUN: %python_executable %imex_runner --requires=l0-runtime -i %s --pass-pipeline-file=%p/xegpu-to-func-vc.pp \
// RUN:                                       --runner imex-cpu-runner -e main \
// RUN:                                       --entry-point-result=void \
// RUN:                                       --shared-libs=%irunner_utils,%mlir_runner_utils,%mlir_c_runner_utils,%levelzero_runtime --filecheck
// RUN: %python_executable %imex_runner --requires=sycl-runtime -i %s --pass-pipeline-file=%p/xegpu-to-func-vc.pp \
// RUN:                                        --runner imex-cpu-runner -e main \
// RUN:                                        --entry-point-result=void \
// RUN:                                        --shared-libs=%irunner_utils,%mlir_runner_utils,%mlir_c_runner_utils,%sycl_runtime --filecheck
module @gemm attributes {gpu.container_module} {
  memref.global "private" @__Aconstant_8x32xf32 : memref<8x32xf32> = dense<1.0>
  memref.global "private" @__Bconstant_8x32xf32 : memref<8x32xf32> = dense<2.0>
  func.func @test(%arg0: memref<8x32xf32>, %arg1: memref<8x32xf32>) -> memref<8x32xf32> attributes {llvm.emit_c_interface} {
    %c1 = arith.constant 1 : index
    %c8 = arith.constant 8 : index
    %c0_f32 = arith.constant 0.0 : f32

    %A = gpu.alloc  host_shared () : memref<8x32xf32>
    memref.copy %arg0, %A : memref<8x32xf32> to memref<8x32xf32>
    %B = gpu.alloc  host_shared () : memref<8x32xf32>
    memref.copy %arg1, %B : memref<8x32xf32> to memref<8x32xf32>

    %C = gpu.alloc  host_shared () : memref<8x32xf32>
    %C_unranked = memref.cast %C : memref<8x32xf32> to memref<*xf32>
    call @fillResource1DF32(%C_unranked, %c0_f32) : (memref<*xf32>, f32) -> ()

    // Create the strided memrefs from A, B, C : first 16 elements of each row
    %A_strided = memref.subview %A[0, 0][8, 16][1, 1] : memref<8x32xf32> to memref<8x16xf32, strided<[32,1], offset: 0>>
    %B_strided = memref.subview %B[0, 0][8, 16][1, 1] : memref<8x32xf32> to memref<8x16xf32, strided<[32,1], offset: 0>>
    %C_strided = memref.subview %C[0, 0][8, 16][1, 1] : memref<8x32xf32> to memref<8x16xf32, strided<[32,1], offset: 0>>

    gpu.launch_func  @test_kernel::@test_kernel blocks in (%c1, %c1, %c1) threads in (%c8, %c1, %c1) args(%A_strided : memref<8x16xf32, strided<[32,1], offset: 0>>, %B_strided  : memref<8x16xf32, strided<[32,1], offset: 0>>, %C_strided : memref<8x16xf32, strided<[32,1], offset: 0>>)
    gpu.dealloc  %A : memref<8x32xf32>
    gpu.dealloc  %B : memref<8x32xf32>
    return %C : memref<8x32xf32>
  }
  gpu.module @test_kernel attributes {spirv.target_env = #spirv.target_env<#spirv.vce<v1.4, [Addresses, Float16Buffer, Int64, Int16, Int8, Kernel, Linkage, Vector16, GenericPointer, Groups, Float16, Float64, AtomicFloat32AddEXT, ExpectAssumeKHR, SubgroupDispatch, VectorComputeINTEL, VectorAnyINTEL], [SPV_EXT_shader_atomic_float_add, SPV_KHR_expect_assume, SPV_INTEL_vector_compute]>, api=OpenCL, #spirv.resource_limits<>>} {
    gpu.func @test_kernel(%arg0: memref<8x16xf32, strided<[32,1], offset: 0>>, %arg1: memref<8x16xf32, strided<[32,1], offset: 0>>, %arg2: memref<8x16xf32, strided<[32,1], offset: 0>>) kernel attributes {VectorComputeFunctionINTEL, spirv.entry_point_abi = #spirv.entry_point_abi<>} {
      %thread_id_x = gpu.thread_id x

      %0 = xegpu.create_nd_tdesc %arg0[%thread_id_x, 0] : memref<8x16xf32, strided<[32,1], offset: 0>> -> !xegpu.tensor_desc<16xf32>
      %1 = xegpu.load_nd %0  : !xegpu.tensor_desc<16xf32> -> vector<16xf32>
      %2 = xegpu.create_nd_tdesc %arg1[%thread_id_x, 0] : memref<8x16xf32, strided<[32,1], offset: 0>> -> !xegpu.tensor_desc<16xf32>
      %3 = xegpu.load_nd %2  : !xegpu.tensor_desc<16xf32> -> vector<16xf32>
      %4 = arith.addf %3, %1 : vector<16xf32>
      %5 = xegpu.create_nd_tdesc %arg2[%thread_id_x, 0] : memref<8x16xf32, strided<[32,1], offset: 0>> -> !xegpu.tensor_desc<16xf32>
      xegpu.store_nd %4, %5  : vector<16xf32>, !xegpu.tensor_desc<16xf32>
      gpu.return
    }
  }
  func.func @main() attributes {llvm.emit_c_interface} {

    // Allocate/get regular row major memrefs
    %A = memref.get_global @__Aconstant_8x32xf32 : memref<8x32xf32>
    %B = memref.get_global @__Bconstant_8x32xf32 : memref<8x32xf32>

    %result = call @test(%A, %B) : (memref<8x32xf32>, memref<8x32xf32>) -> memref<8x32xf32>

    %result_cast = memref.cast %result : memref<8x32xf32> to memref<*xf32>
    call @printMemrefF32(%result_cast) : (memref<*xf32>) -> ()
    // CHECK: Unranked Memref base@ = {{(0x)?[-9a-f]*}}
    // CHECK-NEXT:[3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0],

    return
  }
  func.func private @fillResource1DF32(memref<*xf32>, f32) attributes {llvm.emit_c_interface}
  func.func private @printMemrefF32(memref<*xf32>) attributes {llvm.emit_c_interface}
}
