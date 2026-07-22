#if defined(__cplusplus)
extern "C"
{
#endif

    char const* git_sha();

    char const* deploy_version() __attribute__((weak));

#if defined(__cplusplus)
}
#endif
