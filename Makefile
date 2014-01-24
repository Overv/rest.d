CC = dmd
#CFLAGS = -O

sample: sample.d rest.d
	dmd sample.d rest.d

.PHONY: test clean
test:
	./sample

clean:
	rm -f sample
