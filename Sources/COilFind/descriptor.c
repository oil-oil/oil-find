#include "coilfind.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { SIFT_FD_MARKER = 0xA7, SIFT_FD_CONTROL_SIZE = 4096 };

int sift_send_fd(int socket, int descriptor) {
    int suppress_sigpipe = 1;
    if (setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &suppress_sigpipe,
                   sizeof(suppress_sigpipe)) < 0) {
        return -1;
    }

    unsigned char marker = SIFT_FD_MARKER;
    struct iovec iov = { .iov_base = &marker, .iov_len = sizeof(marker) };
    union {
        struct cmsghdr alignment;
        unsigned char bytes[CMSG_SPACE(sizeof(int))];
    } control;
    memset(&control, 0, sizeof(control));

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);

    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &descriptor, sizeof(descriptor));

    ssize_t sent = sendmsg(socket, &message, MSG_DONTWAIT);
    if (sent < 0) return -1;
    if (sent != (ssize_t)sizeof(marker)) {
        errno = EIO;
        return -1;
    }
    return 0;
}

static void sift_close_received_rights(struct msghdr *message) {
    if (!message->msg_control || message->msg_controllen < sizeof(struct cmsghdr)) return;

    unsigned char *base = message->msg_control;
    size_t available = message->msg_controllen;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(message); header;
         header = CMSG_NXTHDR(message, header)) {
        size_t offset = (size_t)((unsigned char *)header - base);
        if (offset > available || available - offset < sizeof(*header)) break;
        if (header->cmsg_len < CMSG_LEN(0) || header->cmsg_len > available - offset) break;

        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS) {
            size_t bytes = header->cmsg_len - CMSG_LEN(0);
            const unsigned char *data = CMSG_DATA(header);
            for (size_t i = 0; i + sizeof(int) <= bytes; i += sizeof(int)) {
                int received;
                memcpy(&received, data + i, sizeof(received));
                if (received >= 0) (void)close(received);
            }
        }
    }
}

int sift_receive_fd(int socket) {
    unsigned char marker = 0;
    struct iovec iov = { .iov_base = &marker, .iov_len = sizeof(marker) };
    union {
        struct cmsghdr alignment;
        unsigned char bytes[SIFT_FD_CONTROL_SIZE];
    } control;
    memset(&control, 0, sizeof(control));

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);

    if (recvmsg(socket, &message, 0) < 0) return -1;

    int received_fd = -1;
    size_t descriptor_count = 0;
    int valid_control = 1;
    unsigned char *base = message.msg_control;
    size_t available = message.msg_controllen;
    if (available > sizeof(control.bytes)) {
        available = sizeof(control.bytes);
        valid_control = 0;
    }

    if (available >= sizeof(struct cmsghdr)) {
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header;
             header = CMSG_NXTHDR(&message, header)) {
            size_t offset = (size_t)((unsigned char *)header - base);
            if (offset > available || available - offset < sizeof(*header) ||
                header->cmsg_len < CMSG_LEN(0) || header->cmsg_len > available - offset) {
                valid_control = 0;
                break;
            }

            if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) {
                valid_control = 0;
                continue;
            }

            size_t bytes = header->cmsg_len - CMSG_LEN(0);
            if (bytes % sizeof(int) != 0 || bytes != sizeof(int)) valid_control = 0;
            const unsigned char *data = CMSG_DATA(header);
            for (size_t i = 0; i + sizeof(int) <= bytes; i += sizeof(int)) {
                int fd;
                memcpy(&fd, data + i, sizeof(fd));
                if (fd < 0) {
                    valid_control = 0;
                    continue;
                }
                descriptor_count++;
                if (descriptor_count == 1) received_fd = fd;
            }
        }
    }

    if ((message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0 ||
        marker != SIFT_FD_MARKER || descriptor_count != 1 || !valid_control) {
        sift_close_received_rights(&message);
        errno = EPROTO;
        return -1;
    }

    int flags = fcntl(received_fd, F_GETFD);
    if (flags < 0 || fcntl(received_fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
        int saved_errno = errno;
        (void)close(received_fd);
        errno = saved_errno;
        return -1;
    }
    return received_fd;
}
