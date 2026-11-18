// Trimmed captures of YouTube's WEB `/next` responses for comment replies (video dQw4w9WgXcQ,
// captured live on 2026-11-18): a top-level page whose threads carry `commentRepliesRenderer`
// (reply count text + reply continuation token), the first reply page (with its "Show more
// replies" token) and the second reply page. Only the keys the comments parser reads are kept.
// Generated; do not hand-edit.

import Foundation

enum CommentRepliesFixtures {
    static let firstReplyToken = "Eg0SC2RRdzR3OVdnWGNRGAYygwEaUBIaVWd6S1lrc3FlUTVnQTN0MGcwRjRBYUFCQWciAggAKhhVQ3VBWEZrZ3N3MUw3eGFDZm5kNUpKT3cyC2RRdzR3OVdnWGNRQAFICoIBAggBQi9jb21tZW50LXJlcGxpZXMtaXRlbS1VZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZw%3D%3D"
    static let secondReplyToken = "Eg0SC2RRdzR3OVdnWGNRGAYy2gEKU2dldF9jb21tZW50X3dpdGhfcmVwbGllc19zdHJlYW0tLUNnZ0lnQVFWRjdmUk9CSUZDS0FnR0FFaURnb01DS2JYLVBNRkVLanVtdHdDVUFCWUFRGlASGlVnektZa3NxZVE1Z0EzdDBnMEY0QWFBQkFnIgIIACoYVUN1QVhGa2dzdzFMN3hhQ2ZuZDVKSk93MgtkUXc0dzlXZ1hjUUABSDKCAQIIASgKQi9jb21tZW50LXJlcGxpZXMtaXRlbS1VZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZw%3D%3D"
    static let topLevelIDs = ["UgzKYksqeQ5gA3t0g0F4AaABAg", "Ugw10bSluCDSZMIxUSB4AaABAg"]
    static let replyCountTexts = ["727 replies", "655 replies"]
    static let replyPage1IDs = ["UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT952pvnnAzll", "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT953cxv6qamK", "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT961rS_2wf3F"]
    static let replyPage2IDs = ["UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT96iZXv_6iRD", "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT96rebjG2TlS"]

    static let topLevelPage = #"""
{
  "onResponseReceivedEndpoints": [
    {
      "reloadContinuationItemsCommand": {
        "continuationItems": [
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentKey": "EhpVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZyAoKAE%3D"
                }
              },
              "replies": {
                "commentRepliesRenderer": {
                  "contents": [
                    {
                      "continuationItemRenderer": {
                        "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN",
                        "continuationEndpoint": {
                          "clickTrackingParams": "CMQBEL51IhMItP2ykr-SmAMVdIGxAx3t3w_LygEEoe_3Bw==",
                          "commandMetadata": {
                            "webCommandMetadata": {
                              "sendPost": true,
                              "apiUrl": "/youtubei/v1/next"
                            }
                          },
                          "continuationCommand": {
                            "token": "Eg0SC2RRdzR3OVdnWGNRGAYygwEaUBIaVWd6S1lrc3FlUTVnQTN0MGcwRjRBYUFCQWciAggAKhhVQ3VBWEZrZ3N3MUw3eGFDZm5kNUpKT3cyC2RRdzR3OVdnWGNRQAFICoIBAggBQi9jb21tZW50LXJlcGxpZXMtaXRlbS1VZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZw%3D%3D",
                            "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT"
                          }
                        }
                      }
                    }
                  ],
                  "viewReplies": {
                    "buttonRenderer": {
                      "text": {
                        "runs": [
                          {
                            "text": "727 replies"
                          }
                        ]
                      },
                      "icon": {
                        "iconType": "EXPAND"
                      },
                      "trackingParams": "CMYBEKLABCITCLT9spK_kpgDFXSBsQMd7d8Pyw==",
                      "iconPosition": "BUTTON_ICON_POSITION_TYPE_LEFT_OF_TEXT"
                    }
                  }
                }
              }
            }
          },
          {
            "commentThreadRenderer": {
              "commentViewModel": {
                "commentViewModel": {
                  "commentKey": "EhpVZ3cxMGJTbHVDRFNaTUl4VVNCNEFhQUJBZyAoKAE%3D"
                }
              },
              "replies": {
                "commentRepliesRenderer": {
                  "contents": [
                    {
                      "continuationItemRenderer": {
                        "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN",
                        "continuationEndpoint": {
                          "clickTrackingParams": "CL8BEL51IhMItP2ykr-SmAMVdIGxAx3t3w_LygEEoe_3Bw==",
                          "commandMetadata": {
                            "webCommandMetadata": {
                              "sendPost": true,
                              "apiUrl": "/youtubei/v1/next"
                            }
                          },
                          "continuationCommand": {
                            "token": "Eg0SC2RRdzR3OVdnWGNRGAYygwEaUBIaVWd3MTBiU2x1Q0RTWk1JeFVTQjRBYUFCQWciAggAKhhVQ3VBWEZrZ3N3MUw3eGFDZm5kNUpKT3cyC2RRdzR3OVdnWGNRQAFICoIBAggBQi9jb21tZW50LXJlcGxpZXMtaXRlbS1VZ3cxMGJTbHVDRFNaTUl4VVNCNEFhQUJBZw%3D%3D",
                            "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT"
                          }
                        }
                      }
                    }
                  ],
                  "viewReplies": {
                    "buttonRenderer": {
                      "text": {
                        "runs": [
                          {
                            "text": "655 replies"
                          }
                        ]
                      },
                      "icon": {
                        "iconType": "EXPAND"
                      },
                      "trackingParams": "CMEBEKLABCITCLT9spK_kpgDFXSBsQMd7d8Pyw==",
                      "iconPosition": "BUTTON_ICON_POSITION_TYPE_LEFT_OF_TEXT"
                    }
                  }
                }
              }
            }
          }
        ]
      }
    }
  ],
  "frameworkUpdates": {
    "entityBatchUpdate": {
      "mutations": [
        {
          "entityKey": "EhpVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZyAoKAE%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EhpVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZyAoKAE%3D",
              "properties": {
                "commentId": "UgzKYksqeQ5gA3t0g0F4AaABAg",
                "content": {
                  "content": "I Rick rolled my entire French class because we had to study a city in France and make a quiz about it as well as a presentation, I decided to make a Kahoot quiz because it’s very easy. I put a link in to this saying it’s the kahoot link. The teacher needless to say got very very mad. As well as my classmates asking who rick rolls in 2019"
                },
                "publishedTime": "6 years ago (edited)",
                "replyLevel": 0
              },
              "author": {
                "displayName": "@grustache4569",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_kDD-FhIbth2qcBbI9VGxR41dJa0kE3kN9iVlGzNgRU_g=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "109K",
                "replyCount": "727"
              }
            }
          }
        },
        {
          "entityKey": "EhpVZ3cxMGJTbHVDRFNaTUl4VVNCNEFhQUJBZyAoKAE%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EhpVZ3cxMGJTbHVDRFNaTUl4VVNCNEFhQUJBZyAoKAE%3D",
              "properties": {
                "commentId": "Ugw10bSluCDSZMIxUSB4AaABAg",
                "content": {
                  "content": "Let’s put the meme aside, this is actually a banging song."
                },
                "publishedTime": "6 years ago",
                "replyLevel": 0
              },
              "author": {
                "displayName": "@LK-ht7qz",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/RJnrz4JwDmHNgtFdnVdJ6FKLiuo59IuHkY6bvqaEJM0mxTSlq0GKQs_ItA-sJ8QMqps_lf9Lvgs=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "223K",
                "replyCount": "655"
              }
            }
          }
        }
      ]
    }
  }
}
"""#

    static let replyPage1 = #"""
{
  "onResponseReceivedEndpoints": [
    {
      "reloadContinuationItemsCommand": {
        "continuationItems": [
          {
            "commentViewModel": {
              "commentViewModel": {
                "commentKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk1MnB2bm5BemxsICgoAQ%3D%3D"
              }
            }
          },
          {
            "commentViewModel": {
              "commentViewModel": {
                "commentKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk1M2N4djZxYW1LICgoAQ%3D%3D"
              }
            }
          },
          {
            "commentViewModel": {
              "commentViewModel": {
                "commentKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2MXJTXzJ3ZjNGICgoAQ%3D%3D"
              }
            }
          },
          {
            "continuationItemRenderer": {
              "button": {
                "buttonRenderer": {
                  "text": {
                    "runs": [
                      {
                        "text": "Show more replies"
                      }
                    ]
                  },
                  "icon": {
                    "iconType": "SUBDIRECTORY_ARROW_RIGHT"
                  },
                  "trackingParams": "CDMQ8FsiEwi12piYv5KYAxVf00kHHYn8M_o=",
                  "command": {
                    "clickTrackingParams": "CDMQ8FsiEwi12piYv5KYAxVf00kHHYn8M_rKAQRxG6cs",
                    "commandMetadata": {
                      "webCommandMetadata": {
                        "sendPost": true,
                        "apiUrl": "/youtubei/v1/next"
                      }
                    },
                    "continuationCommand": {
                      "token": "Eg0SC2RRdzR3OVdnWGNRGAYy2gEKU2dldF9jb21tZW50X3dpdGhfcmVwbGllc19zdHJlYW0tLUNnZ0lnQVFWRjdmUk9CSUZDS0FnR0FFaURnb01DS2JYLVBNRkVLanVtdHdDVUFCWUFRGlASGlVnektZa3NxZVE1Z0EzdDBnMEY0QWFBQkFnIgIIACoYVUN1QVhGa2dzdzFMN3hhQ2ZuZDVKSk93MgtkUXc0dzlXZ1hjUUABSDKCAQIIASgKQi9jb21tZW50LXJlcGxpZXMtaXRlbS1VZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZw%3D%3D",
                      "request": "CONTINUATION_REQUEST_TYPE_WATCH_NEXT"
                    }
                  }
                }
              }
            }
          }
        ]
      }
    }
  ],
  "frameworkUpdates": {
    "entityBatchUpdate": {
      "mutations": [
        {
          "entityKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk1MnB2bm5BemxsICgoAQ%3D%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk1MnB2bm5BemxsICgoAQ%3D%3D",
              "properties": {
                "commentId": "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT952pvnnAzll",
                "content": {
                  "content": "The biggest comrade ever"
                },
                "publishedTime": "6 years ago",
                "replyLevel": 1
              },
              "author": {
                "displayName": "@egdog_tm",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/1glim4K6lUrgwfThCmliOU7tTxWQ6Tnl2VSEZKFQNxn5braBtYx8bcljKcvw1U0Cv9LlbcfqIg=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "7K",
                "replyCount": ""
              }
            }
          }
        },
        {
          "entityKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk1M2N4djZxYW1LICgoAQ%3D%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk1M2N4djZxYW1LICgoAQ%3D%3D",
              "properties": {
                "commentId": "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT953cxv6qamK",
                "content": {
                  "content": "You sir, are a legend"
                },
                "publishedTime": "6 years ago",
                "replyLevel": 1
              },
              "author": {
                "displayName": "@andrejhofer2007",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_nHNmhgK4mtwlkvbYzWQNsHe7dvV4nJKisK6SmVW8O7u9Pa8T0cWxyinae9f8_eisKzEw=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "6.4K",
                "replyCount": ""
              }
            }
          }
        },
        {
          "entityKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2MXJTXzJ3ZjNGICgoAQ%3D%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2MXJTXzJ3ZjNGICgoAQ%3D%3D",
              "properties": {
                "commentId": "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT961rS_2wf3F",
                "content": {
                  "content": "respect",
                  "styleRuns": [
                    {
                      "startIndex": 0,
                      "length": 7,
                      "weightLabel": "FONT_WEIGHT_MEDIUM"
                    }
                  ]
                },
                "publishedTime": "6 years ago",
                "replyLevel": 1
              },
              "author": {
                "displayName": "@Kanenfan",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/Q0hjeewb2BhpoOKOEYJ9vBJU-IwUX2aKsnHJhod_RP97N2QQMpcAvikjLpXwQwPoSbWP-9qy=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "4.9K",
                "replyCount": ""
              }
            }
          }
        }
      ]
    }
  }
}
"""#

    static let replyPage2 = #"""
{
  "onResponseReceivedEndpoints": [
    {
      "reloadContinuationItemsCommand": {
        "continuationItems": [
          {
            "commentViewModel": {
              "commentViewModel": {
                "commentKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2aVpYdl82aVJEICgoAQ%3D%3D"
              }
            }
          },
          {
            "commentViewModel": {
              "commentViewModel": {
                "commentKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2cmViakcyVGxTICgoAQ%3D%3D"
              }
            }
          }
        ]
      }
    }
  ],
  "frameworkUpdates": {
    "entityBatchUpdate": {
      "mutations": [
        {
          "entityKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2aVpYdl82aVJEICgoAQ%3D%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2aVpYdl82aVJEICgoAQ%3D%3D",
              "properties": {
                "commentId": "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT96iZXv_6iRD",
                "content": {
                  "content": " @capt_noo  embedded links",
                  "commandRuns": [
                    {
                      "startIndex": 0,
                      "length": 11,
                      "onTap": {
                        "innertubeCommand": {
                          "clickTrackingParams": "COoBELZ1IhMI-6LWrL-SmAMV7c9JBx0uYi37ygEEcJazqA==",
                          "commandMetadata": {
                            "webCommandMetadata": {
                              "url": "/channel/UCSlA4BS7f5-EgTxc_5z1R8A",
                              "webPageType": "WEB_PAGE_TYPE_CHANNEL",
                              "rootVe": 3611,
                              "apiUrl": "/youtubei/v1/browse"
                            }
                          },
                          "browseEndpoint": {
                            "browseId": "UCSlA4BS7f5-EgTxc_5z1R8A",
                            "canonicalBaseUrl": "/channel/UCSlA4BS7f5-EgTxc_5z1R8A"
                          }
                        }
                      }
                    }
                  ],
                  "styleRuns": [
                    {
                      "startIndex": 0,
                      "length": 11,
                      "weightLabel": "FONT_WEIGHT_NORMAL"
                    }
                  ]
                },
                "publishedTime": "6 years ago",
                "replyLevel": 1
              },
              "author": {
                "displayName": "@BoredMurphy",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/55J14b5QWN09PMmYt1SCyv9-YVGC6GRnuvl8olOhBijrliM57t177-G0Rq8nbq9I8UEf0iE8ng=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "267",
                "replyCount": ""
              }
            }
          }
        },
        {
          "entityKey": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2cmViakcyVGxTICgoAQ%3D%3D",
          "type": "ENTITY_MUTATION_TYPE_REPLACE",
          "payload": {
            "commentEntityPayload": {
              "key": "EjFVZ3pLWWtzcWVRNWdBM3QwZzBGNEFhQUJBZy45MWE5WFc3b3NWVDk2cmViakcyVGxTICgoAQ%3D%3D",
              "properties": {
                "commentId": "UgzKYksqeQ5gA3t0g0F4AaABAg.91a9XW7osVT96rebjG2TlS",
                "content": {
                  "content": "L E G E N D lmao"
                },
                "publishedTime": "6 years ago",
                "replyLevel": 1
              },
              "author": {
                "displayName": "@mujtari",
                "avatarThumbnailUrl": "https://yt3.ggpht.com/ytc/AIdro_kV2aQ1eTw0iPYtAAoSLX4W6UXrYEZiyJXuY2gRF3KYCQ9sHb2gmgz0I9YlPB37Sp9E2w=s88-c-k-c0x00ffffff-no-rj"
              },
              "toolbar": {
                "likeCountNotliked": "104",
                "replyCount": ""
              }
            }
          }
        }
      ]
    }
  }
}
"""#
}
