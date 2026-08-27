/* The one call uACPI makes with a struct by value.
 *
 * Everything else it asks of its host takes scalars, and Zig writes those with
 * the C calling convention exactly. A six-byte struct passed by value on i386
 * is the case where "exactly" stops being obvious: it occupies eight bytes of
 * stack, and getting that wrong does not fail to compile, it reads the next
 * argument from the wrong place and writes through whatever was there.
 *
 * So this half is written in the language that defines the convention, and it
 * hands the fields on as scalars. */

#include <uacpi/kernel_api.h>

uacpi_status platd_pci_open(
    uacpi_u16 segment, uacpi_u8 bus, uacpi_u8 device, uacpi_u8 function,
    uacpi_handle *out_handle
);

uacpi_status uacpi_kernel_pci_device_open(
    uacpi_pci_address address, uacpi_handle *out_handle
)
{
    return platd_pci_open(
        address.segment, address.bus, address.device, address.function,
        out_handle
    );
}
