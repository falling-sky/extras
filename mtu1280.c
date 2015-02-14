// Thanks to Austin Marton
// https://austinmarton.wordpress.com/2011/09/14/sending-raw-ethernet-packets-from-a-specific-interface-in-c-on-linux/

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/ip.h>
#include <netinet/udp.h>
#include <netinet/ether.h>
#include <linux/if_packet.h>

// netfilter - lots of stuff pilfered from nfqnl_test.c
#include <linux/netfilter.h>            /* for NF_ACCEPT */
#include <libnetfilter_queue/libnetfilter_queue.h>

#define MTU 1280
#define ETHER_SIZE (6+6+2)
#define IPV6HDR_SIZE 40
#define ICMP6_SIZE 8
#define PAYLOAD_SIZE (MTU-(IPV6HDR_SIZE+ICMP6_SIZE))
#define ETHER_CRC_SIZE 4
#define ETHER_TOTAL_SIZE (MTU + ETHER_SIZE + ETHER_CRC_SIZE)

typedef struct fullframe {
   u_int8_t ether_frame  [ETHER_SIZE];
   u_int8_t ipv6_header  [IPV6HDR_SIZE];
   u_int8_t icmp6_header [ICMP6_SIZE];
   u_int8_t payload [PAYLOAD_SIZE];
   u_int8_t crc [ETHER_CRC_SIZE];
} fullframe;


void hexdump ( char *s,  uint8_t *p, int n) {
          int i;
          printf("\nHEXDUMP: %s\n",s);
          for (i=0;i < n; i++) {
            if (i % 16 == 0) {
              printf("%04x:  ",i);
            }
            printf("%02x", p[i]);
            if (i % 2 == 1) {
              printf(" ");
            }
            if (i % 4 == 3) {
              printf(" ");
            }
            if (i % 16 == 15) {
              printf("\n");
            }
          }
          printf("\n");
}


uint16_t csum(uint16_t *buf, int count)
{
  uint32_t sum;
  for(sum=0; count>0; count-=2)
    sum += *buf++;
  sum = (sum >> 16) + (sum &0xffff);
  sum += (sum >> 16);
  return (uint16_t)(~sum);
}

/* returns packet id */
static u_int32_t block_pkt (struct nfq_data *tb)
{
        int id = 0;
        struct nfqnl_msg_packet_hdr *ph;
        struct nfqnl_msg_packet_hw *hwph;
        u_int32_t mark,ifi; 
        int ret;
        int data_len;
        int copy_len;
        unsigned char *data;
        
        
        // You know what? Screw it.
        // Big ass static block of memory.
        
        
        // I'm tired of fighting all the crud,
        // so I'm goingto just use a big block.
        fullframe buffer;
        memset(&buffer,0,sizeof(buffer));
        assert(sizeof(buffer) == ETHER_TOTAL_SIZE );
        
        // We need
        // Ethernet header
        // IPv6 header
        // IPCMPv6 header
        // As much of the original payload as possible
        // Final ether CRC
        
        
        // Get the packet ID.  NEeded for netfilter_queue response.
        fprintf(stderr,"TRACE: %s %i\n",__FILE__,__LINE__);
        ph = nfq_get_msg_packet_hdr(tb);
        if (ph) {
                id = ntohl(ph->packet_id);
                printf("hw_protocol=0x%04x hook=%u id=%u ",
                        ntohs(ph->hw_protocol), ph->hook, id);
        }
        
        // Get the data payload from netfilter_queue
        fprintf(stderr,"TRACE: %s %i\n",__FILE__,__LINE__);
        ret = nfq_get_payload(tb, &data);
        if (ret >= 0)
                printf("payload_len=%d ", ret);
        data_len = ret;
        copy_len = (data_len > PAYLOAD_SIZE) ? PAYLOAD_SIZE : data_len;
        printf("copy_len=%d ",copy_len);
        
        

        // What MAC address sent us this packet?
        // We intend to send the outbound packet
        // back to the same place.
        hwph = nfq_get_packet_hw(tb);
        if (hwph) {
                int i, hlen = ntohs(hwph->hw_addrlen);

                printf("hw_src_addr=");
                for (i = 0; i < hlen-1; i++)
                        printf("%02x:", hwph->hw_addr[i]);
                printf("%02x ", hwph->hw_addr[hlen-1]);
                
                // Ethernet frame destination
                memcpy(&buffer.ether_frame[0], hwph->hw_addr, 6);
                
        }
        
        // TODO: Ethernet frame source
        
        // Ethernet frame type - ETH_P_IP
        buffer.ether_frame[12] = 0x86;
        buffer.ether_frame[13] = 0xdd;
        
        // Show the ethernet frame
        hexdump("DUMP: ether_frame",buffer.ether_frame,sizeof(buffer.ether_frame));
        
        
        // Start creating the IPv6 header
        buffer.ipv6_header[0] = 0x60;  // IPv6 "version=6"
        
        // What is the payload length?
        int plength = copy_len + ICMP6_SIZE;
        buffer.ipv6_header[4] = plength / 256;
        buffer.ipv6_header[5] = plength % 256;
        
        // What is the next header?
        buffer.ipv6_header[6] = 0x3a;  // ICMPv6
        buffer.ipv6_header[7] = 0xff;  // Hop limit
        
        // Source address, Destination Address
        // Just swap from what we saw in our input packet
        memcpy(&buffer.ipv6_header[8],&data[24],16);
        memcpy(&buffer.ipv6_header[24],&data[8],16);
        
        hexdump("IP6 HEADER:",buffer.ipv6_header,sizeof(buffer.ipv6_header));
        
        // ICMPv6 header
        buffer.icmp6_header[0] = 2;  // Type 2 Packet Too Big
        buffer.icmp6_header[1] = 0;  // Code (not used)
        
        // TODO Checksum
        buffer.icmp6_header[2] = 0;
        buffer.icmp6_header[3] = 0;
        
        // MTU expressed as 32 bits
        buffer.icmp6_header[4] = (MTU >> 24) & 0xff;
        buffer.icmp6_header[5] = (MTU >> 16) & 0xff;
        buffer.icmp6_header[6] = (MTU >> 8) & 0xff;
        buffer.icmp6_header[7] = MTU & 0xff;

        memcpy(buffer.payload, data, copy_len);
        hexdump("ICMP6",buffer.icmp6_header,sizeof(buffer.icmp6_header) + copy_len);
        

        // Device ID that the packet came from
        fprintf(stderr,"TRACE: %s %i\n",__FILE__,__LINE__);
        ifi = nfq_get_indev(tb);
        if (ifi)
                printf("indev=%u ", ifi);

        fputc('\n', stdout);
        fprintf(stderr,"TRACE: %s %i\n",__FILE__,__LINE__);






        return id;
}



/* returns packet id */
static u_int32_t print_pkt (struct nfq_data *tb)
{
        int id = 0;
        struct nfqnl_msg_packet_hdr *ph;
        struct nfqnl_msg_packet_hw *hwph;
        u_int32_t mark,ifi; 
        int ret;
        unsigned char *data;

        ph = nfq_get_msg_packet_hdr(tb);
        if (ph) {
                id = ntohl(ph->packet_id);
                printf("hw_protocol=0x%04x hook=%u id=%u ",
                        ntohs(ph->hw_protocol), ph->hook, id);
        }

        hwph = nfq_get_packet_hw(tb);
        if (hwph) {
                int i, hlen = ntohs(hwph->hw_addrlen);

                printf("hw_src_addr=");
                for (i = 0; i < hlen-1; i++)
                        printf("%02x:", hwph->hw_addr[i]);
                printf("%02x ", hwph->hw_addr[hlen-1]);
        }

        mark = nfq_get_nfmark(tb);
        if (mark)
                printf("mark=%u ", mark);

        ifi = nfq_get_indev(tb);
        if (ifi)
                printf("indev=%u ", ifi);

        ifi = nfq_get_outdev(tb);
        if (ifi)
                printf("outdev=%u ", ifi);
        ifi = nfq_get_physindev(tb);
        if (ifi)
                printf("physindev=%u ", ifi);

        ifi = nfq_get_physoutdev(tb);
        if (ifi)
                printf("physoutdev=%u ", ifi);

        ret = nfq_get_payload(tb, &data);
        if (ret >= 0)
                printf("payload_len=%d ", ret);

        fputc('\n', stdout);

        return id;
}
        

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
              struct nfq_data *nfa, void *data)
{
        static u_int32_t id;
//        id = print_pkt(nfa);
        printf("entering callback\n");
        id = block_pkt(nfa);
        return nfq_set_verdict(qh, id, NF_DROP, 0, NULL);
}



int main(int argc, char **argv)
{
        struct nfq_handle *h;
        struct nfq_q_handle *qh;
        struct nfnl_handle *nh;
        int fd;
        int rv;
        unsigned int queue;
        char *interface;
        char buf[4096] __attribute__ ((aligned));

  if (argc != 3) {
    fprintf(stderr,"usage: a.out interface netgroup\n");
    exit(1);
  }
  interface = argv[1];
  queue = strtol(argv[2],NULL,10);
  

        printf("opening library handle\n");
        h = nfq_open();
        if (!h) {
                fprintf(stderr, "error during nfq_open()\n");
                exit(1);
        }

        printf("unbinding existing nf_queue handler for AF_INET6 (if any)\n");
        if (nfq_unbind_pf(h, AF_INET6) < 0) {
                fprintf(stderr, "error during nfq_unbind_pf()\n");
                exit(1);
        }

        printf("binding nfnetlink_queue as nf_queue handler for AF_INET6\n");
        if (nfq_bind_pf(h, AF_INET6) < 0) {
                fprintf(stderr, "error during nfq_bind_pf()\n");
                exit(1);
        }

        printf("binding this socket to queue '%u'\n",queue);
        qh = nfq_create_queue(h,  queue, &cb, NULL);
        if (!qh) {
                fprintf(stderr, "error during nfq_create_queue()\n");
                exit(1);
        }

        printf("setting copy_packet mode\n");
        if (nfq_set_mode(qh, NFQNL_COPY_PACKET, 0xffff) < 0) {
                fprintf(stderr, "can't set packet_copy mode\n");
                exit(1);
        }

        fd = nfq_fd(h);

        while ((rv = recv(fd, buf, sizeof(buf), 0)) && rv >= 0) {
                printf("pkt received\n");
                nfq_handle_packet(h, buf, rv);
        }

        printf("unbinding from queue 0\n");
        nfq_destroy_queue(qh);

#ifdef INSANE
        /* normally, applications SHOULD NOT issue this command, since
         * it detaches other programs/sockets from AF_INET6, too ! */
        printf("unbinding from AF_INET6\n");
        nfq_unbind_pf(h, AF_INET6);
#endif

        printf("closing library handle\n");
        nfq_close(h);

        exit(0);
}

