// This validator only decodes a file. It never creates BPF handles or programs.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/cilium/ebpf/btf"
)

type fieldCheck struct {
	name         string
	size         int // Zero means any positive size, as for an embedded struct.
	startsAtZero bool
}

func checkStruct(spec *btf.Spec, name string, fields []fieldCheck) error {
	var structure *btf.Struct
	if err := spec.TypeByName(name, &structure); err != nil {
		return fmt.Errorf("find struct %s: %w", name, err)
	}
	if structure.Size == 0 || len(structure.Members) == 0 {
		return fmt.Errorf("struct %s has no complete definition", name)
	}
	fmt.Printf("struct %s: size=%d bytes, members=%d\n", name, structure.Size, len(structure.Members))
	for _, field := range fields {
		var member *btf.Member
		for i := range structure.Members {
			candidate := &structure.Members[i]
			if candidate.Name != field.name {
				continue
			}
			if member != nil {
				return fmt.Errorf("struct %s has duplicate member %s", name, field.name)
			}
			member = candidate
		}
		if member == nil {
			return fmt.Errorf("struct %s is missing member %s", name, field.name)
		}
		if member.BitfieldSize != 0 || member.Offset%8 != 0 {
			return fmt.Errorf("%s.%s: expected a byte-aligned non-bitfield member", name, field.name)
		}
		size, err := btf.Sizeof(member.Type)
		if err != nil {
			return fmt.Errorf("size of %s.%s: %w", name, field.name, err)
		}
		if size <= 0 || (field.size != 0 && size != field.size) {
			return fmt.Errorf("%s.%s: invalid size %d (expected %d; zero means positive)", name, field.name, size, field.size)
		}
		offset := uint64(member.Offset) / 8
		if offset+uint64(size) > uint64(structure.Size) {
			return fmt.Errorf("%s.%s: offset=%d size=%d exceeds struct size=%d", name, field.name, offset, size, structure.Size)
		}
		if field.startsAtZero && offset != 0 {
			return fmt.Errorf("%s.%s: expected offset 0, got %d", name, field.name, offset)
		}
		fmt.Printf("  %s: offset=%d bytes, size=%d bytes, bounds=OK\n", field.name, offset, size)
	}
	return nil
}

func verify(path string) error {
	// LoadSpec also accepts ELF; require standalone little-endian BTF for szr.
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open BTF: %w", err)
	}
	var header [4]byte
	_, readErr := io.ReadFull(file, header[:])
	closeErr := file.Close()
	if readErr != nil {
		return fmt.Errorf("read BTF header: %w", readErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close BTF header file: %w", closeErr)
	}
	if header != [4]byte{0x9f, 0xeb, 1, 0} {
		return fmt.Errorf("expected standalone little-endian BTF v1 (magic 9f eb, version 1, flags 0), got % x", header)
	}

	// This is the same decoder used by dae v2.1.1; no kernel-loading API is used.
	spec, err := btf.LoadSpec(path)
	if err != nil {
		return fmt.Errorf("cilium/ebpf v0.22.0 btf.LoadSpec: %w", err)
	}
	checks := []struct {
		name   string
		fields []fieldCheck
	}{
		{"sock", []fieldCheck{{"__sk_common", 0, true}, {"sk_rcvbuf", 4, false}}},
		{"sk_buff", []fieldCheck{{"len", 4, false}, {"data_len", 4, false}}},
		{"net_device", []fieldCheck{{"name", 16, true}, {"mem_start", 8, false}}},
		{"task_struct", []fieldCheck{{"stack", 8, false}, {"pid", 4, false}, {"tgid", 4, false}}},
	}
	for _, check := range checks {
		if err := checkStruct(spec, check.name, check.fields); err != nil {
			return err
		}
	}
	fmt.Println("PASS: standalone BTF decoded with cilium/ebpf v0.22.0; core structs and representative field bounds verified.")
	fmt.Println("No BPF programs were loaded. This checks decoding and internal bounds, not runtime ABI identity.")
	return nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: verify BTF_PATH")
		os.Exit(2)
	}
	if err := verify(os.Args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "BTF validation failed: %v\n", err)
		os.Exit(1)
	}
}
