CC = dmd
CFLAGS = -g

sample: sample.d rest.d
	dmd $(CFLAGS) sample.d rest.d

.PHONY: test clean
test:
	./sample

clean:
	rm -f sample
