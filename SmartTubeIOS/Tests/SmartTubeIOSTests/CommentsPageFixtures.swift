// Trimmed captures of YouTube's WEB `/next` responses for a comments page (video 9bZkp7q19f0,
// captured live on 2026-11-18). Only the keys the comments parser reads are kept. The first
// page's first thread carries a synthetic reply continuation token, and one reply entity is
// present but unreferenced, to prove replies are skipped. Generated; do not hand-edit.

import Foundation

enum CommentsPageFixtures {
    static let firstNextToken = "Eg0SCzliWmtwN3ExOWYwGAYyWCIxIgs5YlprcDdxMTlmMDAAeAKqAhpVZ3pST3BTcjRhcVp3RVBQXzZkNEFhQUJBZ_ADATABQiFlbmdhZ2VtZW50LXBhbmVsLWNvbW1lbnRzLXNlY3Rpb24%3D"
    static let firstNextCountText = "5.4M"
    static let page1NextToken = "Eg0SCzliWmtwN3ExOWYwGAYylQMK2AJnZXRfcmFua2VkX3N0cmVhbXMtLUNxY0JDSUFFRlJlMzBUZ2FuQUVLbHdFSTJGOFFnQVFZQnlLTUFWczFqTDlpSkVxRmtTYnduTEU2TWxoY2dTR3o3TEQ4UmM3WmpobHFVQ3ZJWkhhT2JVRkpLNVpjQV8tZmNNTmdFVmdhVTNiZUFwV2NjcGNEcy1jUzVTNjhuU1ZFNk5FRmlRUHl1VTBMdGREdGtjS1QweXBqcVVMQkR1dUZoTHZ1Q25wQzFVWDBweEp0WnkzZ1JHMzFNRENVUUo4U1BTOE9SbkdkN1F0aE5DYzRzOV8zaWhhSXpGZEFpTXdBRUJRU0J3aUVJQkFQR0FFU0J3aUpJQkFCR0FBU0JRaW9JQmdBRWdVSWh5QVlBQklGQ0lnZ0dBQVNCUWpBSUJnQUVnY0loU0FRQlJnQkVnVUloaUFZQUJJRkNMc2dHQUJRQUZnQiIRIgs5YlprcDdxMTlmMDAAeAEoFDABQiFlbmdhZ2VtZW50LXBhbmVsLWNvbW1lbnRzLXNlY3Rpb24%3D"
    static let page2NextToken = "Eg0SCzliWmtwN3ExOWYwGAYyrQQK8ANnZXRfcmFua2VkX3N0cmVhbXMtLUNvc0NDSUFFRlJlMzBUZ2FnQUlLLXdFSTJGOFFnQVFZQnlMd0FWUGxyWHY1TUVQWHRwWlJGWFBKQ2lyeHBHb3U2MGtVNzFBRENwWmtDelE4QXdWZjdMeFNkQTVrRUZRSGI0Rm1zMElReTR0NER3WGxsUWNjNHRmQy16OS01dzhnVzBkUHpZaFlSQVNoc1FsT2NtX0dVUFJBUVMxVG1RYmhaaU8yZ3lYWDY4eFZzUkpMTGNUQkZrdjRpQmhMa0F0eTJuUFhjUG1LWTJQRkJQVUdxcWtDcFRUYUQ4endoWDBYUGNRaGFlNUtKZ2xoT21VVWhIZFlGYWZvVm1TUzJHS2VlWmRORFY2aFl0cTBNR3JzSGtLc2pvWVFHOWk4eXB4STJNOE52Y0JBYXc2Sk5FNTZERVlkOEN2Uk5TUmhoTVpoeWcwM0E3ZjhJZWJtUk1Sd1JtM3B6NUZzOXZlMklCbDJGb2dqTXhBb0VnVUloaUFZQUJJRkNJY2dHQUFTQlFpb0lCZ0FFZ2NJaENBUUhoZ0JFZ2NJaVNBUUFSZ0FFZ1VJaUNBWUFCSUZDTUFnR0FBU0J3aUZJQkFLR0FFU0JRaTdJQmdBRWdVSXd5QVlBQklGQ0o4Z0dBQlFBRmdCIhEiCzliWmtwN3ExOWYwMAB4ASgoMAFCIWVuZ2FnZW1lbnQtcGFuZWwtY29tbWVudHMtc2VjdGlvbg%3D%3D"
    static let page1CommentIDs = ["UgzROpSr4aqZwEPP_6d4AaABAg", "UgwjaNDCeA0QYOdKxAp4AaABAg", "Ugw86OuA6TOFQoythjF4AaABAg"]
    static let page2CommentIDs = ["UgxQ3S7P4wnLAAA_aNN4AaABAg", "Ugx-iZkMDo-ri138Qf14AaABAg"]

    static let firstNext = #"""
{
  "engagementPanels": [
    {
      "engagementPanelSectionListRenderer": {
        "content": {
          "sectionListRenderer": {
            "contents": [
              {
                "itemSectionRenderer": {
                  "contents": [
                    {
                      "continuationItemRenderer": {
                        "continuationEndpoint": {
                          "clickTrackingParams": "CD8Quy8YACITCPOAl6PjkZgDFS89VQgdKvcOZcoBBEJJqXA=",
                          "commandMetadata": {
                            "webCommandMetadata": {
                              "apiUrl": "/youtubei/v1/next",
                              "sendPost": true
                            }
                          },
                          "continuationCommand": {
                            "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT",
                            "token": "Eg0SCzliWmtwN3ExOWYwGAYyWCIxIgs5YlprcDdxMTlmMDAAeAKqAhpVZ3pST3BTcjRhcVp3RVBQXzZkNEFhQUJBZ_ADATABQiFlbmdhZ2VtZW50LXBhbmVsLWNvbW1lbnRzLXNlY3Rpb24%3D"
                          }
                        },
                        "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN"
                      }
                    }
                  ],
                  "sectionIdentifier": "comment-item-section",
                  "targetId": "engagement-panel-comments-section",
                  "trackingParams": "CD8Quy8YACITCPOAl6PjkZgDFS89VQgdKvcOZQ=="
                }
              }
            ],
            "trackingParams": "CD4Qui8iEwjzgJej45GYAxUvPVUIHSr3DmU="
          }
        },
        "header": {
          "engagementPanelTitleHeaderRenderer": {
            "contextualInfo": {
              "runs": [
                {
                  "text": "5.4M"
                }
              ]
            },
            "title": {
              "simpleText": "Comments"
            }
          }
        },
        "panelIdentifier": "engagement-panel-comments-section"
      }
    }
  ]
}
"""#

    static let page1 = #"""
{
  "frameworkUpdates": {
    "entityBatchUpdate": {
      "mutations": [
        {
          "entityKey": "EhpVZ3pST3BTcjRhcVp3RVBQXzZkNEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ERSw4DZnwTCa7b-hkjiqLKqWek_2Lx7D1DdaJrmPqPVYUQEn0lFUt9K3D78whbVonWXtBkm6=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@CaptainHYOJUN"
              },
              "properties": {
                "commentId": "UgzROpSr4aqZwEPP_6d4AaABAg",
                "content": {
                  "content": "14년전이라고요...??"
                },
                "publishedTime": "3 days ago"
              },
              "toolbar": {
                "likeCountLiked": "550",
                "likeCountNotliked": "549",
                "replyCount": "26"
              }
            }
          }
        },
        {
          "entityKey": "EhpVZ3dqYU5EQ2VBMFFZT2RLeEFwNEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/wjMTSXxYVoIFgZgc3sV_OtCswjXacrhE5jQE2ev7zAnU4bV2vwQAvRXkKDUbeiSgq7Ad3Lnh5g=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@satibeza1426"
              },
              "properties": {
                "commentId": "UgwjaNDCeA0QYOdKxAp4AaABAg",
                "content": {
                  "content": "Let's pretend this song just came out and everything is right in the world again"
                },
                "publishedTime": "5 years ago"
              },
              "toolbar": {
                "likeCountLiked": "8.1K",
                "likeCountNotliked": "8.1K",
                "replyCount": "56"
              }
            }
          }
        },
        {
          "entityKey": "EhpVZ3c4Nk91QTZUT0ZRb3l0aGpGNEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_kTJzTLQ4dP2zxHs5mfJpfUjy8RRxMCHFN-U145QkBfkQ=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@feesh8198"
              },
              "properties": {
                "commentId": "Ugw86OuA6TOFQoythjF4AaABAg",
                "content": {
                  "content": "Are we seriously going to ignore how well that child danced"
                },
                "publishedTime": "7 years ago"
              },
              "toolbar": {
                "likeCountLiked": "29K",
                "likeCountNotliked": "29K",
                "replyCount": "170"
              }
            }
          }
        },
        {
          "entityKey": "SYNTHETIC-REPLY-ENTITY",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ERSw4DZnwTCa7b-hkjiqLKqWek_2Lx7D1DdaJrmPqPVYUQEn0lFUt9K3D78whbVonWXtBkm6=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@CaptainHYOJUN"
              },
              "properties": {
                "commentId": "reply-1",
                "content": {
                  "content": "A reply that must not appear as a top-level comment"
                },
                "publishedTime": "3 days ago"
              },
              "toolbar": {
                "likeCountLiked": "550",
                "likeCountNotliked": "549",
                "replyCount": "26"
              }
            }
          }
        }
      ]
    }
  },
  "onResponseReceivedEndpoints": [
    {
      "reloadContinuationItemsCommand": {
        "continuationItems": [
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "UgzROpSr4aqZwEPP_6d4AaABAg",
                  "commentKey": "EhpVZ3pST3BTcjRhcVp3RVBQXzZkNEFhQUJBZyAoKAE%3D"
                }
              },
              "replies": {
                "commentRepliesRenderer": {
                  "contents": [
                    {
                      "continuationItemRenderer": {
                        "continuationEndpoint": {
                          "continuationCommand": {
                            "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT",
                            "token": "SYNTHETIC-REPLY-TOKEN-MUST-BE-IGNORED"
                          }
                        }
                      }
                    }
                  ]
                }
              }
            }
          },
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "UgwjaNDCeA0QYOdKxAp4AaABAg",
                  "commentKey": "EhpVZ3dqYU5EQ2VBMFFZT2RLeEFwNEFhQUJBZyAoKAE%3D"
                }
              }
            }
          },
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "Ugw86OuA6TOFQoythjF4AaABAg",
                  "commentKey": "EhpVZ3c4Nk91QTZUT0ZRb3l0aGpGNEFhQUJBZyAoKAE%3D"
                }
              }
            }
          },
          {
            "continuationItemRenderer": {
              "continuationEndpoint": {
                "clickTrackingParams": "CAAQg2ciEwjd0Naj45GYAxUHEHMJHQe5NqLKAQQuVYIr",
                "commandMetadata": {
                  "webCommandMetadata": {
                    "apiUrl": "/youtubei/v1/next",
                    "sendPost": true
                  }
                },
                "continuationCommand": {
                  "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT",
                  "token": "Eg0SCzliWmtwN3ExOWYwGAYylQMK2AJnZXRfcmFua2VkX3N0cmVhbXMtLUNxY0JDSUFFRlJlMzBUZ2FuQUVLbHdFSTJGOFFnQVFZQnlLTUFWczFqTDlpSkVxRmtTYnduTEU2TWxoY2dTR3o3TEQ4UmM3WmpobHFVQ3ZJWkhhT2JVRkpLNVpjQV8tZmNNTmdFVmdhVTNiZUFwV2NjcGNEcy1jUzVTNjhuU1ZFNk5FRmlRUHl1VTBMdGREdGtjS1QweXBqcVVMQkR1dUZoTHZ1Q25wQzFVWDBweEp0WnkzZ1JHMzFNRENVUUo4U1BTOE9SbkdkN1F0aE5DYzRzOV8zaWhhSXpGZEFpTXdBRUJRU0J3aUVJQkFQR0FFU0J3aUpJQkFCR0FBU0JRaW9JQmdBRWdVSWh5QVlBQklGQ0lnZ0dBQVNCUWpBSUJnQUVnY0loU0FRQlJnQkVnVUloaUFZQUJJRkNMc2dHQUJRQUZnQiIRIgs5YlprcDdxMTlmMDAAeAEoFDABQiFlbmdhZ2VtZW50LXBhbmVsLWNvbW1lbnRzLXNlY3Rpb24%3D"
                }
              },
              "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN"
            }
          }
        ],
        "targetId": "comments-section"
      }
    }
  ]
}
"""#

    static let page2 = #"""
{
  "frameworkUpdates": {
    "entityBatchUpdate": {
      "mutations": [
        {
          "entityKey": "EhpVZ3hRM1M3UDR3bkxBQUFfYU5ONEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_kCO068LTHBfoY2C_5s4oVplyJXk9Yru_6-V5dUMSSbzI8=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@AnnaYouTubeCreator"
              },
              "properties": {
                "commentId": "UgxQ3S7P4wnLAAA_aNN4AaABAg",
                "content": {
                  "content": "Globally Korean famous before squid game btw"
                },
                "publishedTime": "6 days ago"
              },
              "toolbar": {
                "likeCountLiked": "73",
                "likeCountNotliked": "72",
                "replyCount": ""
              }
            }
          }
        },
        {
          "entityKey": "EhpVZ3gtaVprTURvLXJpMTM4UWYxNEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_mY8E2H8MzRB1WuHDUxYaNkZzczprnelvuKfVmgAD84j6BYXs-S1dBV_qjRfgHcyJL0jw=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@omardurovic2220"
              },
              "properties": {
                "commentId": "Ugx-iZkMDo-ri138Qf14AaABAg",
                "content": {
                  "content": "I think this song should literally be analysed more. Because it's the most addictive and groovey song ever made to this day."
                },
                "publishedTime": "6 days ago"
              },
              "toolbar": {
                "likeCountLiked": "41",
                "likeCountNotliked": "40",
                "replyCount": ""
              }
            }
          }
        }
      ]
    }
  },
  "onResponseReceivedEndpoints": [
    {
      "appendContinuationItemsAction": {
        "continuationItems": [
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "UgxQ3S7P4wnLAAA_aNN4AaABAg",
                  "commentKey": "EhpVZ3hRM1M3UDR3bkxBQUFfYU5ONEFhQUJBZyAoKAE%3D"
                }
              }
            }
          },
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "Ugx-iZkMDo-ri138Qf14AaABAg",
                  "commentKey": "EhpVZ3gtaVprTURvLXJpMTM4UWYxNEFhQUJBZyAoKAE%3D"
                }
              }
            }
          },
          {
            "continuationItemRenderer": {
              "continuationEndpoint": {
                "clickTrackingParams": "CAAQg2ciEwjg3-yj45GYAxU5HAYAHby6DhPKAQQnuR80",
                "commandMetadata": {
                  "webCommandMetadata": {
                    "apiUrl": "/youtubei/v1/next",
                    "sendPost": true
                  }
                },
                "continuationCommand": {
                  "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT",
                  "token": "Eg0SCzliWmtwN3ExOWYwGAYyrQQK8ANnZXRfcmFua2VkX3N0cmVhbXMtLUNvc0NDSUFFRlJlMzBUZ2FnQUlLLXdFSTJGOFFnQVFZQnlMd0FWUGxyWHY1TUVQWHRwWlJGWFBKQ2lyeHBHb3U2MGtVNzFBRENwWmtDelE4QXdWZjdMeFNkQTVrRUZRSGI0Rm1zMElReTR0NER3WGxsUWNjNHRmQy16OS01dzhnVzBkUHpZaFlSQVNoc1FsT2NtX0dVUFJBUVMxVG1RYmhaaU8yZ3lYWDY4eFZzUkpMTGNUQkZrdjRpQmhMa0F0eTJuUFhjUG1LWTJQRkJQVUdxcWtDcFRUYUQ4endoWDBYUGNRaGFlNUtKZ2xoT21VVWhIZFlGYWZvVm1TUzJHS2VlWmRORFY2aFl0cTBNR3JzSGtLc2pvWVFHOWk4eXB4STJNOE52Y0JBYXc2Sk5FNTZERVlkOEN2Uk5TUmhoTVpoeWcwM0E3ZjhJZWJtUk1Sd1JtM3B6NUZzOXZlMklCbDJGb2dqTXhBb0VnVUloaUFZQUJJRkNJY2dHQUFTQlFpb0lCZ0FFZ2NJaENBUUhoZ0JFZ2NJaVNBUUFSZ0FFZ1VJaUNBWUFCSUZDTUFnR0FBU0J3aUZJQkFLR0FFU0JRaTdJQmdBRWdVSXd5QVlBQklGQ0o4Z0dBQlFBRmdCIhEiCzliWmtwN3ExOWYwMAB4ASgoMAFCIWVuZ2FnZW1lbnQtcGFuZWwtY29tbWVudHMtc2VjdGlvbg%3D%3D"
                }
              },
              "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN"
            }
          }
        ]
      }
    }
  ]
}
"""#

    static let page2Last = #"""
{
  "frameworkUpdates": {
    "entityBatchUpdate": {
      "mutations": [
        {
          "entityKey": "EhpVZ3hRM1M3UDR3bkxBQUFfYU5ONEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_kCO068LTHBfoY2C_5s4oVplyJXk9Yru_6-V5dUMSSbzI8=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@AnnaYouTubeCreator"
              },
              "properties": {
                "commentId": "UgxQ3S7P4wnLAAA_aNN4AaABAg",
                "content": {
                  "content": "Globally Korean famous before squid game btw"
                },
                "publishedTime": "6 days ago"
              },
              "toolbar": {
                "likeCountLiked": "73",
                "likeCountNotliked": "72",
                "replyCount": ""
              }
            }
          }
        },
        {
          "entityKey": "EhpVZ3gtaVprTURvLXJpMTM4UWYxNEFhQUJBZyAoKAE%3D",
          "payload": {
            "commentEntityPayload": {
              "author": {
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_mY8E2H8MzRB1WuHDUxYaNkZzczprnelvuKfVmgAD84j6BYXs-S1dBV_qjRfgHcyJL0jw=s88-c-k-c0x00ffffff-no-rj",
                "displayName": "@omardurovic2220"
              },
              "properties": {
                "commentId": "Ugx-iZkMDo-ri138Qf14AaABAg",
                "content": {
                  "content": "I think this song should literally be analysed more. Because it's the most addictive and groovey song ever made to this day."
                },
                "publishedTime": "6 days ago"
              },
              "toolbar": {
                "likeCountLiked": "41",
                "likeCountNotliked": "40",
                "replyCount": ""
              }
            }
          }
        }
      ]
    }
  },
  "onResponseReceivedEndpoints": [
    {
      "appendContinuationItemsAction": {
        "continuationItems": [
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "UgxQ3S7P4wnLAAA_aNN4AaABAg",
                  "commentKey": "EhpVZ3hRM1M3UDR3bkxBQUFfYU5ONEFhQUJBZyAoKAE%3D"
                }
              }
            }
          },
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentId": "Ugx-iZkMDo-ri138Qf14AaABAg",
                  "commentKey": "EhpVZ3gtaVprTURvLXJpMTM4UWYxNEFhQUJBZyAoKAE%3D"
                }
              }
            }
          }
        ]
      }
    }
  ]
}
"""#
}
