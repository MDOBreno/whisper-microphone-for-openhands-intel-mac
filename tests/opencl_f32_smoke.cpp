#define CL_TARGET_OPENCL_VERSION 120
#include <OpenCL/cl.h>

#include <algorithm>
#include <cmath>
#include <ctime>
#include <cstdio>
#include <cstdlib>
#include <vector>

static const char * kernel_source = R"CLC(
__kernel void tiled_mm(__global const char * a, ulong oa,
                       __global const char * b, ulong ob,
                       __global char * c, ulong oc, int k, int m, int n) {
    const uint lx = get_local_id(0), ly = get_local_id(1);
    const ulong row = (ulong)get_group_id(0) * 16 + lx;
    const ulong col = (ulong)get_group_id(1) * 16 + ly;
    __local float at[16][16], bt[16][16];
    float sum = 0.0f;
    for (uint tile = 0; tile < ((uint)k + 15) / 16; ++tile) {
        const ulong ak = (ulong)tile * 16 + ly;
        const ulong bk = (ulong)tile * 16 + lx;
        at[lx][ly] = row < (ulong)m && ak < (ulong)k
            ? ((__global const float *)(a + oa))[row*(ulong)k+ak] : 0.0f;
        bt[lx][ly] = bk < (ulong)k && col < (ulong)n
            ? ((__global const float *)(b + ob))[col*(ulong)k+bk] : 0.0f;
        barrier(CLK_LOCAL_MEM_FENCE);
        for (uint q = 0; q < 16; ++q) sum = fma(at[lx][q], bt[q][ly], sum);
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    if (row < (ulong)m && col < (ulong)n) ((__global float *)(c + oc))[col*(ulong)m+row] = sum;
}
)CLC";

int main(int argc, char ** argv) {
    const int k = argc > 1 ? std::atoi(argv[1]) : 1280;
    const int m = argc > 2 ? std::atoi(argv[2]) : 16;
    const int n = argc > 3 ? std::atoi(argv[3]) : 16;
    const size_t oa = argc > 4 ? (size_t)std::strtoull(argv[4], nullptr, 10) : 0;
    const size_t sa = argc > 5 ? (size_t)std::strtoull(argv[5], nullptr, 10) : oa + (size_t)k*m*sizeof(float);
    const size_t ob = argc > 6 ? (size_t)std::strtoull(argv[6], nullptr, 10) : 0;
    const size_t sb = argc > 7 ? (size_t)std::strtoull(argv[7], nullptr, 10) : ob + (size_t)k*n*sizeof(float);
    const size_t oc = argc > 8 ? (size_t)std::strtoull(argv[8], nullptr, 10) : 0;
    const size_t sc = argc > 9 ? (size_t)std::strtoull(argv[9], nullptr, 10) : oc + (size_t)m*n*sizeof(float);
    const int device_index = std::getenv("GGML_OPENCL_DEVICE") ? std::atoi(std::getenv("GGML_OPENCL_DEVICE")) : 2;
    cl_uint np = 0;
    if (clGetPlatformIDs(0, nullptr, &np) != CL_SUCCESS || np == 0) return 2;
    std::vector<cl_platform_id> platforms(np);
    clGetPlatformIDs(np, platforms.data(), nullptr);
    cl_platform_id platform = platforms[0];
    cl_uint nd = 0;
    if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 0, nullptr, &nd) != CL_SUCCESS || device_index < 0 || (cl_uint)device_index >= nd) return 3;
    std::vector<cl_device_id> devices(nd);
    clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, nd, devices.data(), nullptr);
    char name[256] = {};
    clGetDeviceInfo(devices[device_index], CL_DEVICE_NAME, sizeof(name), name, nullptr);
    std::printf("device[%d]=%s shape k=%d m=%d n=%d buffers=%zu/%zu/%zu offsets=%zu/%zu/%zu\n",
        device_index, name, k, m, n, sa, sb, sc, oa, ob, oc);

    cl_int err = CL_SUCCESS;
    cl_context context = clCreateContext(nullptr, 1, &devices[device_index], nullptr, nullptr, &err);
    if (!context || err != CL_SUCCESS) { std::printf("context error %d\n", err); return 4; }
    cl_command_queue queue = clCreateCommandQueue(context, devices[device_index], 0, &err);
    if (!queue || err != CL_SUCCESS) { std::printf("queue error %d\n", err); return 5; }
    cl_program program = clCreateProgramWithSource(context, 1, &kernel_source, nullptr, &err);
    err = clBuildProgram(program, 1, &devices[device_index],
        "-cl-std=CL1.2 -cl-mad-enable -cl-unsafe-math-optimizations -cl-finite-math-only -cl-fast-relaxed-math -DGGML_OPENCL_FP32_FALLBACK",
        nullptr, nullptr);
    if (err != CL_SUCCESS) {
        size_t bytes = 0;
        clGetProgramBuildInfo(program, devices[device_index], CL_PROGRAM_BUILD_LOG, 0, nullptr, &bytes);
        std::vector<char> log(bytes + 1);
        clGetProgramBuildInfo(program, devices[device_index], CL_PROGRAM_BUILD_LOG, bytes, log.data(), nullptr);
        std::printf("build error %d: %s\n", err, log.data()); return 6;
    }
    cl_kernel kernel = clCreateKernel(program, "tiled_mm", &err);
    std::vector<float> a((size_t)k*m), b((size_t)k*n), c((size_t)m*n, 0), ref((size_t)m*n, 0);
    for (size_t i=0; i<a.size(); ++i) a[i] = std::sin((float)i*0.01f);
    for (size_t i=0; i<b.size(); ++i) b[i] = std::cos((float)i*0.013f);
    cl_mem da=clCreateBuffer(context,CL_MEM_READ_WRITE,sa,nullptr,&err);
    cl_mem db=clCreateBuffer(context,CL_MEM_READ_WRITE,sb,nullptr,&err);
    cl_mem dc=clCreateBuffer(context,CL_MEM_READ_WRITE,sc,nullptr,&err);
    if (err==CL_SUCCESS) err=clEnqueueWriteBuffer(queue,da,CL_TRUE,oa,a.size()*sizeof(float),a.data(),0,nullptr,nullptr);
    if (err==CL_SUCCESS) err=clEnqueueWriteBuffer(queue,db,CL_TRUE,ob,b.size()*sizeof(float),b.data(),0,nullptr,nullptr);
    clSetKernelArg(kernel,0,sizeof(da),&da); clSetKernelArg(kernel,1,sizeof(cl_ulong),&oa);
    clSetKernelArg(kernel,2,sizeof(db),&db); clSetKernelArg(kernel,3,sizeof(cl_ulong),&ob);
    clSetKernelArg(kernel,4,sizeof(dc),&dc); clSetKernelArg(kernel,5,sizeof(cl_ulong),&oc);
    clSetKernelArg(kernel,6,sizeof(k),&k); clSetKernelArg(kernel,7,sizeof(m),&m); clSetKernelArg(kernel,8,sizeof(n),&n);
    const size_t local[]={16,16};
    const size_t global[]={((size_t)m+15)/16*16,((size_t)n+15)/16*16};
    const double start=(double)clock()/CLOCKS_PER_SEC;
    err=clEnqueueNDRangeKernel(queue,kernel,2,nullptr,global,local,0,nullptr,nullptr);
    if (err==CL_SUCCESS) err=clFinish(queue);
    if (err==CL_SUCCESS) err=clEnqueueReadBuffer(queue,dc,CL_TRUE,oc,c.size()*sizeof(float),c.data(),0,nullptr,nullptr);
    if (err!=CL_SUCCESS) { std::printf("inference error %d\n",err); return 7; }
    for (int col=0;col<n;++col) for (int row=0;row<m;++row) {
        float sum=0; for(int i=0;i<k;++i) sum=std::fma(a[(size_t)row*k+i],b[(size_t)col*k+i],sum);
        ref[(size_t)col*m+row]=sum;
    }
    float max_abs=0;
    for(size_t i=0;i<c.size();++i) max_abs=std::max(max_abs,std::abs(c[i]-ref[i]));
    std::printf("PASS max_abs_error=%.7g gpu_wall_s=%.3f first=%.7g expected=%.7g\n",
        max_abs, (double)clock()/CLOCKS_PER_SEC-start,c[0],ref[0]);
    clReleaseMemObject(da); clReleaseMemObject(db); clReleaseMemObject(dc);
    clReleaseKernel(kernel); clReleaseProgram(program); clReleaseCommandQueue(queue); clReleaseContext(context);
    return max_abs < 1e-3f ? 0 : 8;
}
